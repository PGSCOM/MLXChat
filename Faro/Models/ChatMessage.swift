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
    /// The model that produced an assistant turn — nil for user turns, and
    /// nil for assistant turns from before this was tracked.
    var modelID: String?
    /// The message this one follows. Nil marks a root (or, for messages
    /// saved before branching existed, "not yet migrated" — see
    /// `MessageTree.threadLegacy`).
    var parentID: UUID?
    /// An image attached to a user message (drag-and-drop or the photo
    /// picker), sent to vision-capable models. `.externalStorage` keeps
    /// this out of the main SwiftData file instead of bloating it.
    @Attribute(.externalStorage) var imageData: Data?
    /// A file attachment's name and extracted text, kept apart from
    /// `content` so editing can change the wording without re-extracting
    /// or losing the file. Older messages baked the attachment straight
    /// into `content` — `promptText` reproduces that format either way.
    var attachmentName: String?
    var attachmentText: String?
    var conversation: Conversation?
    /// JSON-encoded `[ToolCallRecord]` — a stored string, not a relationship,
    /// so a lightweight-migration default (`= "[]"`) is enough to add this
    /// to existing conversations, same trick as `Skill` in `UserDefaults`.
    var toolCallsRaw: String = "[]"

    init(
        role: MessageRole, content: String, reasoning: String? = nil, imageData: Data? = nil,
        attachmentName: String? = nil, attachmentText: String? = nil, parentID: UUID? = nil
    ) {
        id = UUID()
        roleRaw = role.rawValue
        self.content = content
        self.reasoning = reasoning
        self.imageData = imageData
        self.attachmentName = attachmentName
        self.attachmentText = attachmentText
        self.parentID = parentID
        createdAt = .now
    }

    var role: MessageRole {
        MessageRole(rawValue: roleRaw) ?? .user
    }

    var toolCalls: [ToolCallRecord] {
        get { (try? JSONDecoder().decode([ToolCallRecord].self, from: Data(toolCallsRaw.utf8))) ?? [] }
        set { toolCallsRaw = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }

    /// What actually gets sent to the model: the attachment (if any)
    /// wrapped around what the person typed, same shape as the original
    /// inline format so old and new messages prompt identically.
    var promptText: String {
        guard let attachmentName, let attachmentText else { return content }
        return "Archivo adjunto: \(attachmentName)\n\n\(attachmentText)\n\n---\n\n\(content)"
    }
}

/// Pure functions over a conversation's flat message array, read as the
/// tree branching makes it: every message points at its parent, editing a
/// user turn or regenerating a reply adds a sibling instead of overwriting
/// history.
enum MessageTree {
    /// Walks parent links from `leafID` up to a root, returned oldest-first
    /// — the branch currently on screen.
    static func path(to leafID: UUID, in messages: [ChatMessage]) -> [ChatMessage] {
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var chain: [ChatMessage] = []
        var current = byID[leafID]
        while let message = current {
            chain.append(message)
            current = message.parentID.flatMap { byID[$0] }
        }
        return chain.reversed()
    }

    /// Every message sharing `message.parentID`, oldest first — the
    /// versions a branch selector switches between.
    static func siblings(of message: ChatMessage, in messages: [ChatMessage]) -> [ChatMessage] {
        messages
            .filter { $0.parentID == message.parentID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Descends through each node's newest child until a leaf, so switching
    /// branches always lands on the latest reply down that path.
    static func latestLeaf(from message: ChatMessage, in messages: [ChatMessage]) -> ChatMessage {
        var current = message
        while let next = messages
            .filter({ $0.parentID == current.id })
            .max(by: { $0.createdAt < $1.createdAt }) {
            current = next
        }
        return current
    }

    /// Links a flat, pre-branching message list (`parentID == nil`
    /// everywhere) into a single chain by `createdAt`, so a conversation
    /// saved before this feature existed gets a well-formed tree the first
    /// time it's opened. Messages that already carry a `parentID` are left
    /// untouched.
    static func threadLegacy(_ messages: [ChatMessage]) {
        let unthreaded = messages.filter { $0.parentID == nil }.sorted { $0.createdAt < $1.createdAt }
        for (previous, current) in zip(unthreaded, unthreaded.dropFirst()) {
            current.parentID = previous.id
        }
    }
}
