import Foundation
import SwiftData

@Model
final class Conversation {
    var id: UUID
    var title: String
    /// Hugging Face repo id used to answer in this conversation, e.g.
    /// "mlx-community/Qwen2.5-0.5B-Instruct-4bit".
    var modelID: String
    var systemPrompt: String
    var createdAt: Date

    // Generation settings. Recommended values are used unless
    // `useCustomGeneration` is on — see `effectiveGenerationSettings`.
    var useCustomGeneration: Bool = false
    var customTemperature: Double = GenerationSettings.recommended.temperature
    var customTopP: Double = GenerationSettings.recommended.topP
    var customTopK: Int = GenerationSettings.recommended.topK
    var customMinP: Double = GenerationSettings.recommended.minP
    /// 0 means disabled (mirrors `GenerationSettings.repetitionPenalty == nil`).
    var customRepetitionPenalty: Double = 0
    var customMaxTokens: Int = GenerationSettings.recommended.maxTokens ?? 2048

    @Relationship(deleteRule: .cascade)
    var messages: [ChatMessage] = []

    init(title: String = "Nueva conversación", modelID: String, systemPrompt: String = "") {
        id = UUID()
        self.title = title
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        createdAt = .now
    }

    var effectiveGenerationSettings: GenerationSettings {
        guard useCustomGeneration else { return .recommended }
        return GenerationSettings(
            temperature: customTemperature,
            topP: customTopP,
            topK: customTopK,
            minP: customMinP,
            repetitionPenalty: customRepetitionPenalty > 0 ? customRepetitionPenalty : nil,
            maxTokens: customMaxTokens > 0 ? customMaxTokens : nil
        )
    }

    func resetGenerationSettings() {
        useCustomGeneration = false
        let recommended = GenerationSettings.recommended
        customTemperature = recommended.temperature
        customTopP = recommended.topP
        customTopK = recommended.topK
        customMinP = recommended.minP
        customRepetitionPenalty = 0
        customMaxTokens = recommended.maxTokens ?? 2048
    }
}
