import Foundation
import MCP
import MLXLMCommon

/// Converts between MCP's JSON representation (`MCP.Value`) and
/// MLXLMCommon's (`ToolSpec` / `JSONValue`) — two near-identical JSON
/// mirrors from different packages that were never going to share a type.
enum MCPToolBridge {
    /// An MCP tool's schema → the OpenAI-style function-calling dict
    /// `ChatSession(tools:)` expects.
    static func toolSpec(for tool: MCP.Tool) -> ToolSpec {
        [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description ?? "",
                "parameters": sendableValue(from: tool.inputSchema),
            ] as [String: any Sendable],
        ]
    }

    /// The model's tool-call arguments (`JSONValue`) → MCP's `Value`.
    /// Both are plain recursive JSON mirrors, so round-tripping through
    /// JSON bytes is simpler and safer than a second hand-written
    /// case-by-case converter.
    static func mcpArguments(from arguments: [String: JSONValue]) -> [String: Value] {
        guard let data = try? JSONEncoder().encode(arguments),
            let decoded = try? JSONDecoder().decode([String: Value].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func sendableValue(from value: Value) -> any Sendable {
        switch value {
        case .null: return ""
        case .bool(let flag): return flag
        case .int(let number): return number
        case .double(let number): return number
        case .string(let text): return text
        case .data: return ""
        case .array(let items): return items.map(sendableValue(from:))
        case .object(let fields):
            var result: [String: any Sendable] = [:]
            for (key, field) in fields { result[key] = sendableValue(from: field) }
            return result
        }
    }
}
