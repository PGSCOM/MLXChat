import Foundation

/// A short, hand-picked starting list. Real repo ids, verified against
/// the Hugging Face API (not guessed) — the point of Fase 2 is that this
/// list is a convenience, not a limit: the search tab below reaches any
/// mlx-community (or other) repo directly.
struct CuratedModel: Identifiable, Sendable {
    let id: String
    let displayName: String
    let approxSizeGB: Double
    let isVision: Bool
    let isRecommended: Bool

    static let all: [CuratedModel] = [
        CuratedModel(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            displayName: "Qwen 2.5 · 0.5B", approxSizeGB: 0.3,
            isVision: false, isRecommended: true
        ),
        CuratedModel(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            displayName: "Qwen 2.5 · 1.5B", approxSizeGB: 0.9,
            isVision: false, isRecommended: true
        ),
        CuratedModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 · 3B", approxSizeGB: 1.8,
            isVision: false, isRecommended: false
        ),
        CuratedModel(
            id: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen 3 · 4B", approxSizeGB: 2.3,
            isVision: false, isRecommended: false
        ),
        CuratedModel(
            id: "mlx-community/gemma-3-4b-it-qat-4bit",
            displayName: "Gemma 3 · 4B", approxSizeGB: 2.7,
            isVision: true, isRecommended: false
        ),
        CuratedModel(
            id: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            displayName: "Qwen 3 VL · 4B", approxSizeGB: 2.4,
            isVision: true, isRecommended: false
        ),
    ]
}
