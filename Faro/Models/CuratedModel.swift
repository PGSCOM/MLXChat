import Foundation

/// A short, hand-picked starting list. Real repo ids, verified against
/// the Hugging Face API (not guessed) — a convenience, not a limit: the
/// search tab reaches any mlx-community (or other) repo directly.
///
/// "Recomendado" means every feature of the app works with it on the
/// pinned mlx-swift-lm: tools (skills and MCP) including taking their
/// results back, reasoning that "Directo" can switch off, and multi-turn
/// chat — checked by rendering each chat template the way `ChatSession`
/// does. The first entry in the first family is also `DefaultModel`.
///
/// Deliberately not listed: the `gemma-4-*-qat-mobile` repos
/// (per-tensor `weight_scale`, `quant_method: gemma` — mlx-swift-lm
/// doesn't load that quantization format).
struct CuratedModel: Identifiable, Sendable {
    let id: String
    let displayName: String
    let approxSizeGB: Double
    let isVision: Bool
    /// Read off the model's real chat template (`ModelCapabilityProbe`),
    /// not guessed from its name.
    let supportsReasoning: Bool
    let isRecommended: Bool

    struct Family: Identifiable, Sendable {
        let id: String
        let title: String
        let models: [CuratedModel]
    }

    static let families: [Family] = [
        Family(id: "qwen3.5", title: "Qwen 3.5", models: [
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
        ]),
        Family(id: "gemma4", title: "Gemma 4", models: [
            // Gemma 4's template only opens its reasoning channel when
            // `enable_thinking` is set — "Directo"/"Normal" both answer
            // straight, only "Profundo" reasons.
            CuratedModel(
                id: "mlx-community/gemma-4-e2b-it-4bit",
                displayName: "Gemma 4 · E2B", approxSizeGB: 3.6,
                isVision: true, supportsReasoning: true, isRecommended: false
            ),
            // Larger than E2B; only offer as an optional download on devices
            // with enough free memory for the context and generation cache.
            CuratedModel(
                id: "mlx-community/gemma-4-e4b-it-4bit",
                displayName: "Gemma 4 · E4B", approxSizeGB: 5.2,
                isVision: true, supportsReasoning: true, isRecommended: false
            ),
        ]),
        Family(id: "lfm2.5", title: "LFM 2.5", models: [
            // Light text-only alternative; this Instruct template accepts
            // tools, but does not open a reasoning block for generation.
            CuratedModel(
                id: "mlx-community/LFM2.5-1.2B-Instruct-4bit",
                displayName: "LFM 2.5 · 1.2B Instruct", approxSizeGB: 0.7,
                isVision: false, supportsReasoning: false, isRecommended: false
            ),
            CuratedModel(
                id: "mlx-community/LFM2.5-VL-1.6B-4bit",
                displayName: "LFM 2.5 · VL 1.6B", approxSizeGB: 1.5,
                isVision: true, supportsReasoning: false, isRecommended: false
            ),
            // This repo has a text-only lfm2 config despite its model card's
            // generic mlx-vlm image example. Do not advertise image support.
            CuratedModel(
                id: "mlx-community/LFM2.5-2.6B-4bit",
                displayName: "LFM 2.5 · 2.6B", approxSizeGB: 1.5,
                isVision: false, supportsReasoning: true, isRecommended: false
            ),
        ]),
    ]

    /// Keep flat lookups for downloaded names, the HTTP model list and
    /// the default model without duplicating the family definitions.
    static let all: [CuratedModel] = families.flatMap(\.models)
}
