import Foundation

/// Outcome of one tool/skill invocation, as shown to the person — mirrors
/// Claude Code's inline "running → done" tool-use blocks instead of
/// leaving tool calls invisible inside `ChatSession`.
enum ToolCallStatus: Codable, Hashable, Sendable {
    case running
    case succeeded(preview: String)
    case failed(String)
}

/// One row in a message's tool-call list. Persisted on `ChatMessage` (JSON,
/// same lightweight pattern as `Skill`) so the record survives scrollback
/// and relaunch, not just the live turn.
struct ToolCallRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let isSkill: Bool
    var status: ToolCallStatus
    /// The MCP server that owns this tool — nil for a skill (which never
    /// goes over MCP) or when the owning server couldn't be found.
    var server: String?
    /// The call's arguments, pretty-printed JSON — nil when there were none.
    var arguments: String?

    /// `name: value` pairs from `arguments`, one line, for a summary that's
    /// readable without opening the card. Falls back to nothing rather than
    /// dumping the raw JSON when parsing fails.
    var argumentsSummary: String? {
        guard let arguments, let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let pairs = object.keys.sorted().map { key in
            "\(key): \(object[key].map { "\($0)" } ?? "")"
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: " · ")
    }
}

/// What `InferenceEngine`'s tool dispatch reports as a call starts and
/// ends — a session outlives one turn, so events are addressed by
/// conversation id and matched to their `.started` by `id`.
enum ToolCallEvent: Sendable {
    case started(ToolCallRecord)
    case finished(id: UUID, status: ToolCallStatus)
}

/// One step of an assistant turn, in the order it actually happened:
/// reasoning, a tool call, reasoning again, more tool calls, an answer.
/// Stored on `ChatMessage` alongside the flat `content`/`reasoning` strings
/// — a step only records *where* it sits in those strings (a character
/// range, an offset), never a copy of the text itself, so this only grows
/// at block boundaries (a handful of times per turn), never per token.
struct TurnStep: Codable, Identifiable, Hashable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        /// A `<think>` block: `[start, end)` into `message.reasoning`.
        /// `end == nil` while the block is still being written.
        case reasoning(start: Int, end: Int?)
        case tool(ToolCallRecord)
    }

    let id: UUID
    var kind: Kind
    /// How many characters of `message.content` had already been written
    /// when this step began — where it slots into the visible text.
    let contentOffset: Int
    let startedAt: Date
    var seconds: Double?

    init(id: UUID = UUID(), kind: Kind, contentOffset: Int, startedAt: Date = .now, seconds: Double? = nil) {
        self.id = id
        self.kind = kind
        self.contentOffset = contentOffset
        self.startedAt = startedAt
        self.seconds = seconds
    }
}

/// One piece of an assistant bubble, in display order — either a slice of
/// plain text or a step (reasoning/tool) with the text it covers, if any.
enum TurnTimelineItem: Identifiable, Sendable {
    case text(String)
    case step(TurnStep, text: String?)

    var id: AnyHashable {
        switch self {
        case .text(let text): text
        case .step(let step, _): step.id
        }
    }
}

extension TurnStep {
    /// Interleaves `content` and `steps` back into the order they actually
    /// streamed in: a step is inserted wherever its `contentOffset` falls,
    /// and reasoning steps carry the slice of `reasoning` they cover. A pure
    /// function with no actor isolation, so tests call it directly.
    static func timeline(content: String, reasoning: String, steps: [TurnStep]) -> [TurnTimelineItem] {
        var items: [TurnTimelineItem] = []
        var cursor = content.startIndex
        for step in steps.sorted(by: { $0.contentOffset < $1.contentOffset }) {
            let offset = min(max(step.contentOffset, 0), content.count)
            let cut = content.index(content.startIndex, offsetBy: offset)
            if cut > cursor {
                items.append(.text(String(content[cursor..<cut])))
            }
            cursor = max(cursor, cut)

            switch step.kind {
            case .reasoning(let start, let end):
                let lower = min(max(start, 0), reasoning.count)
                let upper = min(max(end ?? reasoning.count, lower), reasoning.count)
                let from = reasoning.index(reasoning.startIndex, offsetBy: lower)
                let to = reasoning.index(reasoning.startIndex, offsetBy: upper)
                items.append(.step(step, text: String(reasoning[from..<to])))
            case .tool:
                items.append(.step(step, text: nil))
            }
        }
        if cursor < content.endIndex {
            items.append(.text(String(content[cursor...])))
        }
        return items
    }
}
