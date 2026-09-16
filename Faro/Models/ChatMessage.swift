import Foundation
import SwiftData

enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

@Model
final class ChatMessage {
    var id: UUID
    var roleRaw: String
    var content: String
    /// Text captured from a `<think>...</think>` block, shown collapsed
    /// under the visible answer. Nil when the model didn't reason aloud.
    var reasoning: String?
    var createdAt: Date
    var tokensPerSecond: Double?
    var conversation: Conversation?

    init(role: MessageRole, content: String, reasoning: String? = nil) {
        id = UUID()
        roleRaw = role.rawValue
        self.content = content
        self.reasoning = reasoning
        createdAt = .now
    }

    var role: MessageRole {
        MessageRole(rawValue: roleRaw) ?? .user
    }
}
