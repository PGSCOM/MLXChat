import Foundation
import MLX
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// One turn of prior conversation, as plain Sendable data. Kept separate
/// from `ChatMessage` (a SwiftData model, not Sendable) and from
/// `Chat.Message` (MLXLMCommon's type, which can carry non-Sendable media
/// like `CIImage`) so history can cross into the actor safely; the actor
/// builds the real `Chat.Message` values itself from these.
struct HistoryTurn: Sendable {
    let role: MessageRole
    let content: String
}

/// Owns every loaded model and chat session. An actor because
/// `ChatSession` is documented as not thread-safe, and both the in-app
/// chat and the future local API server (Fase 4) generate against the
/// same loaded model — this serializes them onto one queue instead of
/// racing two sessions over one KV cache.
actor InferenceEngine {
    static let shared = InferenceEngine()

    private var containers: [String: ModelContainer] = [:]
    private var sessions: [UUID: ChatSession] = [:]
    private var configuredMemoryLimit = false

    private init() {}

    private func configureMemoryLimitOnce() {
        guard !configuredMemoryLimit else { return }
        // Small MLX buffer cache on top of the model weights themselves —
        // keeps peak memory predictable on-device (mirrors MLXChatExample).
        Memory.cacheLimit = 20 * 1024 * 1024
        configuredMemoryLimit = true
    }

    /// Downloads (if needed) and loads any Hugging Face repo id — not
    /// limited to a fixed registry. Cached per repo id for the process
    /// lifetime.
    ///
    /// ponytail: uses the macro's default `HubClient`, whose cache lands
    /// under `Library/Caches` — iOS is allowed to purge that under disk
    /// pressure, which would silently re-trigger a multi-GB re-download.
    /// Upgrade path: replace `#huggingFaceLoadModelContainer` with the
    /// hand-rolled `Downloader` conformance pointed at a `HubCache` in
    /// `Application Support`, if this turns out to actually happen.
    func loadContainer(
        modelID: String,
        progress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        configureMemoryLimitOnce()
        if let existing = containers[modelID] {
            return existing
        }
        let container = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: modelID),
            progressHandler: progress
        )
        containers[modelID] = container
        return container
    }

    private func chatMessages(from history: [HistoryTurn]) -> [Chat.Message] {
        history.map { turn in
            switch turn.role {
            case .system: .system(turn.content)
            case .user: .user(turn.content)
            case .assistant: .assistant(turn.content)
            }
        }
    }

    /// Returns the live session for a conversation, creating it (with the
    /// given history, for prompt re-hydration) on first use.
    private func session(
        conversationID: UUID,
        modelID: String,
        systemPrompt: String,
        history: [HistoryTurn],
        settings: GenerationSettings
    ) async throws -> ChatSession {
        if let existing = sessions[conversationID] {
            return existing
        }
        let container = try await loadContainer(modelID: modelID)
        let session = ChatSession(
            container,
            instructions: systemPrompt.isEmpty ? nil : systemPrompt,
            history: chatMessages(from: history),
            generateParameters: settings.makeParameters()
        )
        sessions[conversationID] = session
        return session
    }

    /// Drops a conversation's live session (e.g. after clearing chat or
    /// changing its model) so the next turn rebuilds it from scratch.
    func invalidateSession(conversationID: UUID) {
        sessions[conversationID] = nil
    }

    func streamResponse(
        conversationID: UUID,
        modelID: String,
        systemPrompt: String,
        history: [HistoryTurn],
        settings: GenerationSettings,
        prompt: String
    ) async throws -> AsyncThrowingStream<Generation, Error> {
        let session = try await session(
            conversationID: conversationID, modelID: modelID,
            systemPrompt: systemPrompt, history: history, settings: settings
        )
        return session.streamDetails(to: prompt)
    }
}
