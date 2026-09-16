import Foundation
import MLXLMCommon

/// Plain Sendable snapshot of the generation knobs that matter day to
/// day. Crosses into `InferenceEngine`'s actor isolation as this — never
/// as `GenerateParameters` itself — and is turned into the real MLX type
/// only once it's already inside the actor.
struct GenerationSettings: Sendable {
    var temperature: Double = 0.6
    var topP: Double = 1.0
    var topK: Int = 0
    var minP: Double = 0.0
    /// `nil` disables the penalty entirely (MLXLMCommon's own default).
    var repetitionPenalty: Double?
    var maxTokens: Int? = 2048

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
