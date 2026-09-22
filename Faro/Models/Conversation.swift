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
    var thinkingEffortRaw: String = ThinkingEffort.normal.rawValue

    var thinkingEffort: ThinkingEffort {
        get { ThinkingEffort(rawValue: thinkingEffortRaw) ?? .normal }
        set { thinkingEffortRaw = newValue.rawValue }
    }

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

    /// The project this conversation belongs to, if any. Deleting a project
    /// nullifies this rather than cascading — losing a project's grouping
    /// shouldn't take its chat history down with it.
    var project: Project?

    init(title: String = "Nueva conversación", modelID: String, systemPrompt: String = "") {
        id = UUID()
        self.title = title
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        createdAt = .now
    }

    /// The real system prompt sent to the model: the project's context
    /// (instructions + knowledge documents) first, then this conversation's
    /// own prompt.
    var effectiveSystemPrompt: String {
        [project?.contextBlock ?? "", systemPrompt]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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
