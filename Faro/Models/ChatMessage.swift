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
    /// How long the model spent inside its `<think>` block, so the
    /// collapsed disclosure can say so instead of hiding the wait.
    var reasoningSeconds: Double?
    var createdAt: Date
    var tokensPerSecond: Double?
    /// An image attached to a user message (drag-and-drop or the photo
    /// picker), sent to vision-capable models. `.externalStorage` keeps
    /// this out of the main SwiftData file instead of bloating it.
    @Attribute(.externalStorage) var imageData: Data?
    var conversation: Conversation?
    /// JSON-encoded `[ToolCallRecord]` — a stored string, not a relationship,
    /// so a lightweight-migration default (`= "[]"`) is enough to add this
    /// to existing conversations, same trick as `Skill` in `UserDefaults`.
    var toolCallsRaw: String = "[]"

    init(role: MessageRole, content: String, reasoning: String? = nil, imageData: Data? = nil) {
        id = UUID()
        roleRaw = role.rawValue
        self.content = content
        self.reasoning = reasoning
        self.imageData = imageData
        createdAt = .now
    }

    var role: MessageRole {
        MessageRole(rawValue: roleRaw) ?? .user
    }

    var toolCalls: [ToolCallRecord] {
        get { (try? JSONDecoder().decode([ToolCallRecord].self, from: Data(toolCallsRaw.utf8))) ?? [] }
        set { toolCallsRaw = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }
}
