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

    @Relationship(deleteRule: .cascade)
    var messages: [ChatMessage] = []

    init(title: String = "Nueva conversación", modelID: String, systemPrompt: String = "") {
        id = UUID()
        self.title = title
        self.modelID = modelID
        self.systemPrompt = systemPrompt
        createdAt = .now
    }
}
