import Foundation

/// How hard the model should reason, as a soft switch: text hints understood
/// by reasoning-capable chat templates (Qwen3's `/no_think` / `/think`,
/// gpt-oss's `Reasoning: low/high` system hint). No API to target — models
/// that don't recognize the hint just ignore it.
enum ThinkingEffort: String, CaseIterable, Hashable, Sendable {
    case off, normal, high

    var label: String {
        switch self {
        case .off: "Directo"
        case .normal: "Normal"
        case .high: "Profundo"
        }
    }

    /// Appended to the user's prompt text (never shown in their bubble).
    var promptSuffix: String {
        switch self {
        case .off: " /no_think"
        case .normal: ""
        case .high: " /think"
        }
    }

    /// Appended to the system prompt when building the session.
    var systemHint: String {
        switch self {
        case .off: "Reasoning: low"
        case .normal: ""
        case .high: "Reasoning: high"
        }
    }
}
