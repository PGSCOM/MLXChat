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
}

/// What `InferenceEngine`'s tool dispatch reports as a call starts and
/// ends — a session outlives one turn, so events are addressed by
/// conversation id and matched to their `.started` by `id`.
enum ToolCallEvent: Sendable {
    case started(id: UUID, name: String, isSkill: Bool)
    case finished(id: UUID, status: ToolCallStatus)
}
