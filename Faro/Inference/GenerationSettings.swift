import Foundation
import MLXLMCommon

/// Plain Sendable snapshot of the generation knobs that matter day to
/// day. Crosses into `InferenceEngine`'s actor isolation as this — never
/// as `GenerateParameters` itself — and is turned into the real MLX type
/// only once it's already inside the actor.
struct GenerationSettings: Sendable {
    // Qwen's recommended sampling for its reasoning models, rather than
    // sampling the whole distribution of a 4-bit model.
    var temperature: Double = 0.6
    var topP: Double = 0.95
    var topK: Int = 20
    var minP: Double = 0.0
    /// `nil` disables the penalty entirely (MLXLMCommon's own default).
    var repetitionPenalty: Double?
    /// Reasoning and answer share this budget — at 2048 a hybrid model
    /// routinely spent all of it thinking and the turn ended with no answer.
    var maxTokens: Int? = 8192

    static let recommended = GenerationSettings()

    func makeParameters() -> GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(temperature),
            topP: Float(topP),
            topK: topK,
            minP: Float(minP),
            repetitionPenalty: repetitionPenalty.map(Float.init)
        )
    }
}
