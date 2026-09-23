import Foundation
import CoreImage
import MLX
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// One turn of prior conversation, as plain Sendable data. Kept separate
/// from `ChatMessage` (a SwiftData model, not Sendable) and from
/// `Chat.Message` (MLXLMCommon's type, which can carry non-Sendable media
/// like `CIImage`) so history can cross into the actor safely; the actor
/// builds the real `Chat.Message` values itself from these. `imageData` is
/// raw bytes for the same reason — `CIImage` itself doesn't cross safely.
struct HistoryTurn: Sendable {
    let role: MessageRole
    let content: String
    let imageData: Data?

    init(role: MessageRole, content: String, imageData: Data? = nil) {
        self.role = role
        self.content = content
        self.imageData = imageData
    }
}

/// Owns every loaded model and chat session. An actor because
/// `ChatSession` is documented as not thread-safe, and the in-app chat,
/// the local API server, and Siri/App Intents all generate against the
/// same loaded model — this serializes them onto one queue instead of
/// racing multiple sessions over one KV cache.
actor InferenceEngine {
    static let shared = InferenceEngine()

    /// At most one model is kept resident: weights run to several GB and
    /// a phone has no room for a second set, so loading a new model drops
    /// the previous one instead of stacking them until iOS kills the app.
    private var containers: [String: ModelContainer] = [:]
    /// Sessions carry the model they were built against — a session holds
    /// its container alive, so evicting a model has to take its sessions
    /// with it or nothing is actually freed.
    ///
    /// `opensThink`: whether the session's chat template opens the reasoning
    /// block inside the *prompt* (Qwen3.5 and kin), so the model's own
    /// output starts already inside it and only ever emits the closing tag.
    /// Measured per session by rendering the template, never guessed from
    /// the repo id — the session's `enable_thinking` decides it, so the same
    /// model can open the block or pre-close it.
    private var sessions: [UUID: (modelID: String, session: ChatSession, opensThink: Bool)] = [:]
    private var configuredMemoryLimit = false
    /// Where tool-call start/finish events for the turn in flight go, per
    /// conversation. A session (and its baked-in `toolDispatch` closure) is
    /// reused across turns, so this is looked up by conversation id at call
    /// time rather than captured once — a `ToolCallEvent` is `Sendable` and
    /// crossing the actor boundary this way avoids ever having to smuggle a
    /// non-Sendable `ChatMessage` into a `@Sendable` closure.
    private var toolCallContinuations: [UUID: AsyncStream<ToolCallEvent>.Continuation] = [:]

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
        containers = [modelID: container]
        sessions = sessions.filter { $0.value.modelID == modelID }
        return container
    }

    /// Drops the in-memory container for a model — called after its files
    /// are deleted from disk, so a future load re-downloads instead of
    /// silently serving the now-orphaned in-memory copy.
    func evictContainer(modelID: String) {
        containers[modelID] = nil
        sessions = sessions.filter { $0.value.modelID != modelID }
    }

    /// Renders the model's chat template for a throwaway turn, with the
    /// session's own `additionalContext`, and checks whether the resulting
    /// prompt ends inside a still-open `<think>` — true for templates that
    /// pre-inject the opening tag into the *prompt* (Qwen3.5 and kin), so
    /// the model's own output only ever emits the closing half.
    private static func promptOpensThink(
        _ container: ModelContainer, additionalContext: [String: any Sendable]?
    ) async -> Bool {
        let messages: [MLXLMCommon.Message] = [["role": "user", "content": "hola"]]
        let prompt = try? await container.perform { (context: ModelContext) -> String in
            context.tokenizer.decode(
                tokenIds: try context.tokenizer.applyChatTemplate(
                    messages: messages, tools: nil, additionalContext: additionalContext))
        }
        guard let prompt else { return false }
        return Self.endsInsideThink(prompt)
    }

    /// True when the last `<think>` in the text has no `</think>` after it.
    static func endsInsideThink(_ text: String) -> Bool {
        guard let open = text.range(of: "<think>", options: .backwards) else { return false }
        guard let close = text.range(of: "</think>", options: .backwards) else { return true }
        return close.lowerBound < open.lowerBound
    }

    /// Replays the opening tag the template already spent in the prompt, so
    /// every consumer's `ThinkTagSplitter` sees a normal `<think>` block
    /// from the first token instead of only learning at the closing tag
    /// that the whole answer so far was reasoning.
    private static func replayingOpenTag(
        _ stream: AsyncThrowingStream<Generation, Error>
    ) -> AsyncThrowingStream<Generation, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.chunk("<think>"))
                do {
                    for try await generation in stream { continuation.yield(generation) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func chatMessages(from history: [HistoryTurn]) -> [Chat.Message] {
        history.map { turn in
            switch turn.role {
            case .system: .system(turn.content)
            case .user: .user(turn.content, images: Self.images(from: turn.imageData))
            case .assistant: .assistant(turn.content)
            }
        }
    }

    /// Builds `UserInput.Image`s from raw bytes — only ever non-empty for
    /// user turns, since only a user attaches an image.
    private static func images(from data: Data?) -> [UserInput.Image] {
        guard let data, let image = CIImage(data: data) else { return [] }
        return [.ciImage(image)]
    }

    /// Returns the live session for a conversation, creating it (with the
    /// given history, for prompt re-hydration) on first use.
    private func session(
        conversationID: UUID,
        modelID: String,
        systemPrompt: String,
        history: [HistoryTurn],
        settings: GenerationSettings,
        enableThinking: Bool?,
        progress: @Sendable @escaping (Progress) -> Void
    ) async throws -> (session: ChatSession, opensThink: Bool) {
        if let existing = sessions[conversationID], existing.modelID == modelID {
            return (existing.session, existing.opensThink)
        }
        let container = try await loadContainer(modelID: modelID, progress: progress)
        let mcpTools = await MCPConnectionManager.shared.enabledToolSpecs()
        // Offered only to a template that can take a tool's result back —
        // otherwise the first tool call throws mid-answer. `nil` (template
        // unreadable) keeps them.
        let takesTools = ModelCapabilityProbe.onDisk(modelID: modelID)?.supportsTools != false
        let tools: [ToolSpec] = takesTools ? SkillStore.toolSpecs() + mcpTools : []

        // Pulled out with explicit types: a ternary between `nil` and a
        // closure literal, inlined as a call argument, previously made
        // the type-checker crash instead of diagnosing.
        let toolSpecs: [ToolSpec]? = tools.isEmpty ? nil : tools
        let dispatch: (@Sendable (ToolCall) async throws -> String)? = tools.isEmpty
            ? nil
            : { @Sendable (call: ToolCall) async throws -> String in
                let callID = UUID()
                let skill = SkillStore.all.first { $0.mode == .automatic && $0.toolName == call.function.name }
                await self.reportToolCall(
                    conversationID: conversationID,
                    .started(id: callID, name: skill?.name ?? call.function.name, isSkill: skill != nil)
                )
                do {
                    // A skill call resolves right here — its "result" is its
                    // instructions, never sent over MCP.
                    let result: String
                    if let skill { result = skill.instructions } else { result = try await MCPConnectionManager.shared.dispatch(call) }
                    let preview = String(result.prefix(160))
                    await self.reportToolCall(conversationID: conversationID, .finished(id: callID, status: .succeeded(preview: preview)))
                    return result
                } catch {
                    await self.reportToolCall(conversationID: conversationID, .finished(id: callID, status: .failed(error.localizedDescription)))
                    throw error
                }
            }

        // The system prompt goes in as the first history message, not as
        // `instructions`: `ChatSession` (mlx-swift-lm 3.31.4) renders
        // `instructions` again on every turn and appends them to the KV
        // cache, so the profile, skills and project documents would pile
        // up once per turn. As history they're rendered exactly once.
        let system: [Chat.Message] = systemPrompt.isEmpty ? [] : [.system(systemPrompt)]
        let additionalContext: [String: any Sendable]? = enableThinking.map { ["enable_thinking": $0] }
        let session = ChatSession(
            container,
            history: system + chatMessages(from: history),
            generateParameters: settings.makeParameters(),
            additionalContext: additionalContext,
            tools: toolSpecs,
            toolDispatch: dispatch
        )
        let opensThink = await Self.promptOpensThink(container, additionalContext: additionalContext)
        sessions[conversationID] = (modelID, session, opensThink)
        return (session, opensThink)
    }

    /// Drops a conversation's live session (e.g. after clearing chat or
    /// changing its model) so the next turn rebuilds it from scratch.
    func invalidateSession(conversationID: UUID) {
        sessions[conversationID] = nil
        toolCallContinuations[conversationID] = nil
        Task { @MainActor in
            AppleFoundationEngine.shared.invalidateSession(conversationID: conversationID)
        }
    }

    private func reportToolCall(conversationID: UUID, _ event: ToolCallEvent) {
        toolCallContinuations[conversationID]?.yield(event)
    }

    /// Skills and MCP servers are global — a single `UserDefaults`-backed
    /// list and one shared `MCPConnectionManager` — not per-conversation, so
    /// unlike `invalidateSession`, a change to either has to drop every
    /// cached session at once rather than one conversation's. Apple's engine
    /// isn't touched: it has no tools wired in (see `streamResponse` below).
    func invalidateAllSessions() {
        sessions = [:]
        toolCallContinuations = [:]
    }

    /// Tool-call events for one conversation's turn in flight. Call this
    /// right before `streamResponse` and consume it concurrently — each
    /// call replaces the previous listener, so it's always this turn's
    /// caller that hears about a call, even though the session (and its
    /// `toolDispatch` closure) may be several turns old.
    func toolCallEvents(conversationID: UUID) -> AsyncStream<ToolCallEvent> {
        let (stream, continuation) = AsyncStream<ToolCallEvent>.makeStream()
        toolCallContinuations[conversationID] = continuation
        return stream
    }

    func streamResponse(
        conversationID: UUID,
        modelID: String,
        systemPrompt: String,
        history: [HistoryTurn],
        settings: GenerationSettings,
        enableThinking: Bool? = nil,
        prompt: String,
        imageData: Data? = nil,
        progress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> AsyncThrowingStream<Generation, Error> {
        // Apple's model isn't a Hugging Face repo: branch before anything
        // touches MLX, the container cache or HubCache. It also has no
        // tool support wired in (see AppleFoundationEngine), so there is
        // nothing to report.
        if AppleFoundationModel.isAppleFoundation(modelID) {
            return try await AppleFoundationEngine.shared.streamResponse(
                conversationID: conversationID, systemPrompt: systemPrompt,
                history: history, settings: settings, prompt: prompt, imageData: imageData
            )
        }
        let (session, opensThink) = try await self.session(
            conversationID: conversationID, modelID: modelID,
            systemPrompt: systemPrompt, history: history, settings: settings,
            enableThinking: enableThinking, progress: progress
        )
        let stream = session.streamDetails(to: prompt, images: Self.images(from: imageData))
        guard opensThink else { return stream }
        return Self.replayingOpenTag(stream)
    }
}
