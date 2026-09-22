import Foundation

/// A short, hand-picked starting list. Real repo ids, verified against
/// the Hugging Face API (not guessed) — a convenience, not a limit: the
/// search tab reaches any mlx-community (or other) repo directly.
struct CuratedModel: Identifiable, Sendable {
    let id: String
    let displayName: String
    let approxSizeGB: Double
    let isVision: Bool
    /// Verified against the model's real chat template with
    /// `ModelCapabilityProbe`, not guessed from its name or family — see
    /// the entries below for what each one's template actually does.
    let supportsReasoning: Bool
    let isRecommended: Bool

    static let all: [CuratedModel] = [
        // Qwen3.5 is the only family here where BOTH tool-calling and
        // reasoning are explicitly supported by the exact mlx-swift-lm
        // version this app is pinned to (3.31.4): `ToolCallFormat.infer`
        // maps its `model_type` ("qwen3_5") to `.xmlFunction`, and its own
        // chat template documents and emits exactly that dialect. Its
        // generation prompt ends by opening `<think>` — the same
        // `templateOpensThink` → `replayingOpenTag` path `InferenceEngine`
        // already has — and closes it immediately when thinking is off.
        // Also the two most-downloaded models in `mlx-community` today.
        CuratedModel(
            id: "mlx-community/Qwen3.5-2B-MLX-4bit",
            displayName: "Qwen 3.5 · 2B", approxSizeGB: 1.7,
            isVision: false, supportsReasoning: true, isRecommended: true
        ),
        CuratedModel(
            id: "mlx-community/Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen 3.5 · 4B", approxSizeGB: 3.0,
            isVision: false, supportsReasoning: true, isRecommended: true
        ),
        // Smallest hybrid model that both reasons and calls tools reliably —
        // ties for #1 in the 2026 Local Agent Bench tool-calling score with
        // models 6× its size, at a fraction of the thinking time. Fits on
        // any iPhone.
        CuratedModel(
            id: "mlx-community/Qwen3-0.6B-4bit",
            displayName: "Qwen 3 · 0.6B", approxSizeGB: 0.34,
            isVision: false, supportsReasoning: true, isRecommended: true
        ),
        // The family investigated in depth this session — reopens `<think>`
        // implicitly on every turn, including right after a tool result,
        // which is exactly what the `ThinkTagSplitter` fix in this branch
        // covers.
        CuratedModel(
            id: "mlx-community/Qwen3-4B-Thinking-2507-4bit",
            displayName: "Qwen 3 Thinking · 4B", approxSizeGB: 2.3,
            isVision: false, supportsReasoning: true, isRecommended: true
        ),
        // Hybrid reasoning, safe tool-calling template, fully open — a
        // non-Qwen alternative so the list isn't just one family.
        CuratedModel(
            id: "mlx-community/SmolLM3-3B-4bit",
            displayName: "SmolLM 3 · 3B", approxSizeGB: 1.7,
            isVision: false, supportsReasoning: true, isRecommended: true
        ),
        CuratedModel(
            id: "mlx-community/Qwen3-1.7B-4bit",
            displayName: "Qwen 3 · 1.7B", approxSizeGB: 1.0,
            isVision: false, supportsReasoning: true, isRecommended: true
        ),
        // Call tools (the default JSON dialect) but their template never
        // mentions `<think>` — verified, not assumed.
        CuratedModel(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            displayName: "Qwen 2.5 · 0.5B", approxSizeGB: 0.3,
            isVision: false, supportsReasoning: false, isRecommended: false
        ),
        CuratedModel(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            displayName: "Qwen 2.5 · 1.5B", approxSizeGB: 0.9,
            isVision: false, supportsReasoning: false, isRecommended: false
        ),
        CuratedModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 · 3B", approxSizeGB: 1.8,
            isVision: false, supportsReasoning: false, isRecommended: false
        ),
        CuratedModel(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen 3 · 4B", approxSizeGB: 2.3,
            isVision: false, supportsReasoning: false, isRecommended: false
        ),
        // Kept for vision. Gemma 3's template doesn't mention `tools` or
        // `<think>` at all; Qwen 3 VL calls tools but doesn't reason.
        CuratedModel(
            id: "mlx-community/gemma-3-4b-it-qat-4bit",
            displayName: "Gemma 3 · 4B", approxSizeGB: 2.7,
            isVision: true, supportsReasoning: false, isRecommended: false
        ),
        CuratedModel(
            id: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            displayName: "Qwen 3 VL · 4B", approxSizeGB: 2.4,
            isVision: true, supportsReasoning: false, isRecommended: false
        ),
    ]
}
