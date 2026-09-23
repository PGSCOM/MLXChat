import Foundation

/// A short, hand-picked starting list. Real repo ids, verified against
/// the Hugging Face API (not guessed) — a convenience, not a limit: the
/// search tab reaches any mlx-community (or other) repo directly.
///
/// "Recomendado" means every feature of the app works with it on the
/// pinned mlx-swift-lm: tools (skills and MCP) including taking their
/// results back, reasoning that "Directo" can switch off, and multi-turn
/// chat — checked by rendering each chat template the way `ChatSession`
/// does. The first entry is also `DefaultModel`.
///
/// Deliberately not listed: Qwen3.5 (its template refuses the turn that
/// hands a tool's result back — see `ModelCapabilityProbe.supportsTools`),
/// Qwen3-2507 Thinking (reasoning can't be switched off) and SmolLM3 (its
/// template reads `xml_tools`, never `tools`).
struct CuratedModel: Identifiable, Sendable {
    let id: String
    let displayName: String
    let approxSizeGB: Double
    let isVision: Bool
    /// Read off the model's real chat template (`ModelCapabilityProbe`),
    /// not guessed from its name.
    let supportsReasoning: Bool
    let isRecommended: Bool

    static let all: [CuratedModel] = [
        CuratedModel(
            id: "mlx-community/Qwen3-1.7B-4bit",
            displayName: "Qwen 3 · 1.7B", approxSizeGB: 1.0,
            isVision: false, supportsReasoning: true, isRecommended: true
        ),
        CuratedModel(
            id: "mlx-community/Qwen3-4B-4bit",
            displayName: "Qwen 3 · 4B", approxSizeGB: 2.3,
            isVision: false, supportsReasoning: true, isRecommended: true
        ),
        // Same template as above: the smallest download, with noticeably
        // weaker answers.
        CuratedModel(
            id: "mlx-community/Qwen3-0.6B-4bit",
            displayName: "Qwen 3 · 0.6B", approxSizeGB: 0.34,
            isVision: false, supportsReasoning: true, isRecommended: false
        ),
        // Vision. Qwen 3 VL calls tools but doesn't reason; Gemma 3's
        // template has neither.
        CuratedModel(
            id: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            displayName: "Qwen 3 VL · 4B", approxSizeGB: 3.1,
            isVision: true, supportsReasoning: false, isRecommended: false
        ),
        CuratedModel(
            id: "mlx-community/gemma-3-4b-it-qat-4bit",
            displayName: "Gemma 3 · 4B", approxSizeGB: 3.0,
            isVision: true, supportsReasoning: false, isRecommended: false
        ),
    ]
}
