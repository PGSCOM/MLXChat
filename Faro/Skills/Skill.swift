import Foundation
import MLXLMCommon

/// Whether a skill is exposed to the model as a tool it can decide to call
/// (like claude.ai), or always folded into the system prompt (for small
/// on-device models that don't reliably call tools at all). A single mode
/// instead of two booleans: a skill can't end up both "always on" and
/// "wait to be called" at once, and an always-on skill isn't also exposed
/// as a tool — that would pay its context twice.
enum SkillMode: String, Codable, CaseIterable, Hashable, Sendable {
    case off, automatic, always

    var label: String {
        switch self {
        case .off: "Desactivada"
        case .automatic: "Automática"
        case .always: "Siempre activa"
        }
    }
}

struct Skill: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// What the model reads to decide whether to call this skill — same
    /// role as a SKILL.md's `description` frontmatter.
    var summary: String
    var instructions: String
    var mode: SkillMode = .automatic

    /// Tool name the model calls. Prefixed so it can never collide with an
    /// MCP server's own tool names.
    var toolName: String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "skill_" + String(slug)
    }
}

/// Persisted skills. `UserDefaults`-backed — these are short strings, and
/// `UserDefaults` is thread-safe so the `InferenceEngine` actor can read it
/// directly without crossing a Sendable boundary.
///
/// ponytail: move to SwiftData if a skill ever needs to carry attachments.
enum SkillStore {
    private static let key = "skills"

    static var all: [Skill] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Skill].self, from: data)) ?? []
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Schemas for skills the model must decide to call — handed straight
    /// to `ChatSession(tools:)`, same shape as `MCPToolBridge.toolSpec`. No
    /// parameters: calling the tool just returns its instructions.
    static func toolSpecs() -> [ToolSpec] {
        all.filter { $0.mode == .automatic }.map { skill -> ToolSpec in
            let parameters: [String: any Sendable] = ["type": "object", "properties": [String: any Sendable]()]
            let function: [String: any Sendable] = [
                "name": skill.toolName,
                "description": skill.summary,
                "parameters": parameters,
            ]
            return ["type": "function", "function": function]
        }
    }

    /// A tool call's result IS the skill's instructions.
    static func instructions(forTool toolName: String) -> String? {
        all.first { $0.mode == .automatic && $0.toolName == toolName }?.instructions
    }

    /// Folded into the system prompt unconditionally — no tool call needed.
    static func alwaysOnInstructions() -> String {
        all.filter { $0.mode == .always }.map(\.instructions).joined(separator: "\n\n")
    }

    /// Parses a `SKILL.md`-style file: a `name:`/`description:` YAML
    /// frontmatter between `---` lines, then the body as instructions. Lets
    /// a skill exported from claude.ai or Claude Code be imported as-is.
    static func parse(skillMarkdown text: String, fallbackName: String) -> Skill {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return Skill(name: fallbackName, summary: "", instructions: text)
        }
        var name = fallbackName
        var summary = ""
        for line in lines[1..<closingIndex] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "name", !value.isEmpty { name = value }
            if key == "description" { summary = value }
        }
        let body = lines[(closingIndex + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Skill(name: name, summary: summary, instructions: body)
    }
}
