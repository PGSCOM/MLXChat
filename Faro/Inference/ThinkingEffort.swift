import Foundation

/// How much the model should reason, handed to the chat template as its
/// `enable_thinking` variable — the switch hybrid templates (Qwen3, Qwen3.5,
/// SmolLM3) actually read. A `/no_think` hint in the prompt only worked on
/// the first Qwen3 releases; newer templates ignore it and reason anyway.
/// Templates that don't read the variable just ignore it.
enum ThinkingEffort: String, CaseIterable, Hashable, Sendable {
    case off, normal, high

    var label: String {
        switch self {
        case .off: "Directo"
        case .normal: "Normal"
        case .high: "Profundo"
        }
    }

    /// `nil` leaves the model's own default: on for most hybrids, off for
    /// some small ones (Qwen3.5-0.8B) — "Profundo" turns it on either way.
    var enableThinking: Bool? {
        switch self {
        case .off: false
        case .normal: nil
        case .high: true
        }
    }
}
