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
/// Deliberately not listed: Gemma 4 E4B (fits few devices at 5+ GB) and
/// the `gemma-4-*-qat-mobile` repos (a quantization format — per-tensor
/// `weight_scale`, `quant_method: gemma` — mlx-swift-lm doesn't load).
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
            id: "mlx-community/Qwen3.5-2B-4bit",
            displayName: "Qwen 3.5 · 2B", approxSizeGB: 1.7,
            isVision: true, supportsReasoning: true, isRecommended: true
        ),
        CuratedModel(
            id: "mlx-community/Qwen3.5-4B-4bit",
            displayName: "Qwen 3.5 · 4B", approxSizeGB: 3.0,
            isVision: true, supportsReasoning: true, isRecommended: true
        ),
        // Best quality in the family (32 vs 27 on Artificial Analysis'
        // Intelligence Index), but 5.95 GB puts it closest to the edge on
        // a 12 GB iPad once the app, context, and generation buffer are
        // accounted for — not the default, but worth offering explicitly.
        CuratedModel(
            id: "mlx-community/Qwen3.5-9B-4bit",
            displayName: "Qwen 3.5 · 9B", approxSizeGB: 5.95,
            isVision: true, supportsReasoning: true, isRecommended: false
        ),
        // Smallest download, with noticeably weaker answers.
        CuratedModel(
            id: "mlx-community/Qwen3.5-0.8B-4bit",
            displayName: "Qwen 3.5 · 0.8B", approxSizeGB: 0.6,
            isVision: true, supportsReasoning: true, isRecommended: false
        ),
        // Gemma 4's template only opens its reasoning channel when
        // `enable_thinking` is set — "Directo"/"Normal" both answer
        // straight, only "Profundo" reasons.
        CuratedModel(
            id: "mlx-community/gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 · E2B", approxSizeGB: 3.6,
            isVision: true, supportsReasoning: true, isRecommended: false
        ),
    ]
}
