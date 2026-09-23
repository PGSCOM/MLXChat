import Foundation
import Observation
import SwiftData
import MLXLMCommon

/// What the current turn is actually doing, so the transcript can say so
/// instead of showing an unexplained spinner. Drives both the live status
/// line and `isGenerating`.
enum TurnPhase: Equatable, Sendable {
    case idle
    case preparing
    case thinking
    case writing
}

@Observable
@MainActor
final class ChatViewModel {
    let conversation: Conversation
    private let modelContext: SwiftData.ModelContext

    private(set) var phase: TurnPhase = .idle
    /// When the current phase began — the live status line counts from it.
    private(set) var phaseStartedAt = Date()
    /// The assistant message being streamed right now, if any.
    private(set) var streamingMessageID: UUID?
    /// What the current model can actually do — `nil` until its on-disk chat
    /// template has been read (right away, at `init` and on every model
    /// switch — no need to wait for the model to load, or even for a first
    /// turn). Drives the UI disabling controls that wouldn't do anything for
    /// this model, instead of guessing from its repo id.
    private(set) var capabilities: ModelCapabilityProbe.Capabilities?
    var errorMessage: String?
    var draft = ""
    private(set) var pendingAttachment: ExtractedAttachment?
    private(set) var pendingImageData: Data?

    private var generateTask: Task<Void, Never>?

    init(conversation: Conversation, modelContext: SwiftData.ModelContext) {
        self.conversation = conversation
        self.modelContext = modelContext
        refreshCapabilities()
    }

    var isGenerating: Bool { phase != .idle }

    var messages: [ChatMessage] {
        conversation.messages.sorted { $0.createdAt < $1.createdAt }
    }

    func attach(url: URL) {
        do {
            pendingAttachment = try AttachmentExtractor.extractSecurityScoped(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Used by drag-and-drop, which already extracts the file off the
    /// main actor (the dropped item's temp file only lives for the
    /// duration of the item provider's completion handler).
    func setAttachment(_ attachment: ExtractedAttachment) {
        pendingAttachment = attachment
    }

    func removeAttachment() {
        pendingAttachment = nil
    }

    func attachImage(data: Data) {
        pendingImageData = data
    }

    func removeImage() {
        pendingImageData = nil
    }

    func send() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || pendingAttachment != nil || pendingImageData != nil, !isGenerating else { return }
        draft = ""
        errorMessage = nil

        let defaultText = pendingAttachment != nil ? "Resume este archivo." : "Describe esta imagen."
        var text = typed.isEmpty ? defaultText : typed
        if let attachment = pendingAttachment {
            let notice = attachment.wasTruncated ? "\n\n[el archivo se truncó por longitud]" : ""
            text = "Archivo adjunto: \(attachment.fileName)\n\n\(attachment.text)\(notice)\n\n---\n\n\(text)"
            pendingAttachment = nil
        }
        let imageData = pendingImageData
        pendingImageData = nil

        // History excludes this turn: the user text goes in as the prompt,
        // and the empty assistant placeholder is filled in place as it
        // streams. Placeholders left behind by a failed turn are skipped —
        // an empty assistant turn is not something to re-feed the model.
        let history = messages
            .filter { !($0.role == .assistant && $0.content.isEmpty) }
            .map { HistoryTurn(role: $0.role, content: $0.content, imageData: $0.imageData) }

        let userMessage = ChatMessage(role: .user, content: text, imageData: imageData)
        userMessage.conversation = conversation
        modelContext.insert(userMessage)
        conversation.messages.append(userMessage)
        nameConversationIfNeeded(from: typed.isEmpty ? defaultText : typed)

        let assistantMessage = ChatMessage(role: .assistant, content: "")
        assistantMessage.conversation = conversation
        modelContext.insert(assistantMessage)
        conversation.messages.append(assistantMessage)
        try? modelContext.save()

        enter(.preparing)
        streamingMessageID = assistantMessage.id

        let conversationID = conversation.id
        let modelID = conversation.modelID
        let effort = conversation.thinkingEffort
        let style = conversation.responseStyle ?? Personalization.style
        let systemPrompt = [
            Personalization.preamble(style: style),
            SkillStore.alwaysOnInstructions(),
            conversation.effectiveSystemPrompt,
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let settings = conversation.effectiveGenerationSettings
        let prompt = text

        let downloadCoordinator = ModelDownloadCoordinator.shared
        // Apple's model is already on the device: there is no download or
        // paging-in to report, so no load band either.
        if !AppleFoundationModel.isAppleFoundation(modelID) {
            downloadCoordinator.beginLoad(id: modelID)
        }

        generateTask = Task {
            var splitter = ThinkTagSplitter()
            let streamStartedAt = Date()
            var reasoningStartedAt: Date?
            var stoppedAtTokenLimit = false
            // Registered before the stream starts, so a tool call on the
            // very first turn isn't missed. Runs concurrently with the
            // generation loop below rather than as a callback threaded
            // through the actor boundary, since it mutates `assistantMessage`
            // (a SwiftData model, not `Sendable`) directly — safe here
            // because this nested task, like the outer one, inherits this
            // method's MainActor isolation.
            let toolCallTask = Task {
                for await event in await InferenceEngine.shared.toolCallEvents(conversationID: conversationID) {
                    switch event {
                    case .started(let id, let name, let isSkill):
                        assistantMessage.toolCalls.append(ToolCallRecord(id: id, name: name, isSkill: isSkill, status: .running))
                    case .finished(let id, let status):
                        guard let index = assistantMessage.toolCalls.firstIndex(where: { $0.id == id }) else { continue }
                        var calls = assistantMessage.toolCalls
                        calls[index].status = status
                        assistantMessage.toolCalls = calls
                    }
                }
            }
            defer { toolCallTask.cancel() }
            do {
                let stream = try await InferenceEngine.shared.streamResponse(
                    conversationID: conversationID, modelID: modelID,
                    systemPrompt: systemPrompt, history: history,
                    settings: settings, enableThinking: effort.enableThinking,
                    prompt: prompt, imageData: imageData,
                    progress: { value in
                        // `.shared` referenced inside the hop, not captured
                        // by this `@Sendable` closure, since the coordinator
                        // itself (a `@MainActor` class) isn't `Sendable`.
                        Task { @MainActor in ModelDownloadCoordinator.shared.record(id: modelID, value: value) }
                    })
                downloadCoordinator.finishLoad(id: modelID)
                // The model is in memory and the first token hasn't landed
                // yet — that wait is thinking, not preparing.
                enter(.thinking)
                for try await generation in stream {
                    switch generation {
                    case .chunk(let piece):
                        let delta = splitter.consume(piece)
                        if delta.contentWasReasoning {
                            // A bare `</think>` arrived: move only what
                            // leaked since the last block boundary, not the
                            // whole bubble — which can also hold real answer
                            // text an earlier *explicit* block already
                            // vouched for (see `Delta.reclaimedContentLength`).
                            let content = assistantMessage.content
                            let cut = content.index(content.endIndex, offsetBy: -delta.reclaimedContentLength)
                            assistantMessage.reasoning = (assistantMessage.reasoning ?? "") + content[cut...]
                            assistantMessage.content = String(content[..<cut])
                            reasoningStartedAt = reasoningStartedAt ?? streamStartedAt
                        }
                        if !delta.reasoning.isEmpty {
                            if reasoningStartedAt == nil { reasoningStartedAt = .now }
                            enter(.thinking)
                            assistantMessage.reasoning = (assistantMessage.reasoning ?? "") + delta.reasoning
                        }
                        if !delta.content.isEmpty {
                            closeReasoning(on: assistantMessage, startedAt: reasoningStartedAt)
                            enter(.writing)
                            assistantMessage.content += delta.content
                        }
                    case .info(let info):
                        assistantMessage.tokensPerSecond = info.tokensPerSecond
                        stoppedAtTokenLimit = info.stopReason == .length
                    default:
                        // Tool calls are resolved inside ChatSession itself
                        // (see InferenceEngine) and reported separately via
                        // `toolCallTask` above; nothing else reaches here.
                        break
                    }
                }
            } catch is CancellationError {
                // User cancelled: keep whatever streamed so far.
            } catch {
                errorMessage = error.localizedDescription
            }
            downloadCoordinator.finishLoad(id: modelID)

            // Whatever the splitter was still holding back as possible
            // tag-boundary lookahead is now final — release it.
            let tail = splitter.finish()
            if !tail.reasoning.isEmpty {
                assistantMessage.reasoning = (assistantMessage.reasoning ?? "") + tail.reasoning
            }
            if !tail.content.isEmpty {
                assistantMessage.content += tail.content
            }
            closeReasoning(on: assistantMessage, startedAt: reasoningStartedAt)

            if stoppedAtTokenLimit {
                errorMessage = assistantMessage.content.isEmpty
                    ? "El modelo agotó el máximo de tokens razonando y no llegó a responder. Prueba «Directo» o sube el máximo en Generación."
                    : "La respuesta se cortó al llegar al máximo de tokens."
            }

            // Only a clean turn with no reasoning leaves a KV cache worth
            // continuing from: `ChatSession` appends every turn and never
            // re-renders, so this turn's reasoning (or a half-finished turn)
            // would stay in the context for the rest of the conversation,
            // paid for in memory on every later turn, where the chat
            // template itself would have dropped it. The next turn rebuilds
            // from the saved transcript instead.
            let hadReasoning = !(assistantMessage.reasoning ?? "").isEmpty
            if hadReasoning || errorMessage != nil || Task.isCancelled {
                await InferenceEngine.shared.invalidateSession(conversationID: conversationID)
            }

            // A turn that produced nothing at all (failed load, immediate
            // cancel) would otherwise leave an empty bubble behind forever.
            if assistantMessage.content.isEmpty && (assistantMessage.reasoning ?? "").isEmpty {
                conversation.messages.removeAll { $0.id == assistantMessage.id }
                modelContext.delete(assistantMessage)
            }

            streamingMessageID = nil
            enter(.idle)
            try? modelContext.save()
        }
    }

    func cancel() {
        generateTask?.cancel()
    }

    func setThinkingEffort(_ effort: ThinkingEffort) {
        guard effort != conversation.thinkingEffort else { return }
        conversation.thinkingEffort = effort
        try? modelContext.save()
        invalidateSession()
    }

    func setResponseStyle(_ style: ResponseStyle?) {
        guard style != conversation.responseStyle else { return }
        conversation.responseStyle = style
        try? modelContext.save()
        invalidateSession()
    }

    func changeModel(to modelID: String) {
        guard modelID != conversation.modelID else { return }
        conversation.modelID = modelID
        // Every model pick in the app funnels through here, so this is the
        // one place that has to remember it for the next new conversation.
        AppSettings.lastModelID = modelID
        try? modelContext.save()
        invalidateSession()
        refreshCapabilities()
    }

    /// Reads the new model's chat template off disk — not from the running
    /// container, so this doesn't wait for a load. `nil` while in flight (and
    /// for a model that was picked but never downloaded — there's nothing on
    /// disk to read yet) rather than showing the previous model's answer.
    private func refreshCapabilities() {
        let modelID = conversation.modelID
        capabilities = nil
        Task {
            capabilities = await Task.detached(priority: .utility) {
                ModelCapabilityProbe.onDisk(modelID: modelID)
            }.value
        }
    }

    /// Called when the generation-settings sheet is dismissed: the live
    /// session (if any) still has the OLD `GenerateParameters` baked in,
    /// so drop it and let the next turn build a fresh one.
    func applyGenerationSettingsChange() {
        try? modelContext.save()
        invalidateSession()
    }

    private func enter(_ newPhase: TurnPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        phaseStartedAt = .now
    }

    /// Called every time content resumes after reasoning — `reasoningStartedAt`
    /// stays pinned to the *first* segment's start, so a turn with more than
    /// one reasoning block (a tool call in between) keeps recomputing the
    /// running total instead of freezing it at the first block's duration.
    private func closeReasoning(on message: ChatMessage, startedAt: Date?) {
        guard let startedAt else { return }
        message.reasoningSeconds = Date().timeIntervalSince(startedAt)
    }

    /// The sidebar is useless when every row reads "Nueva conversación",
    /// so the first thing actually asked becomes the title.
    private func nameConversationIfNeeded(from text: String) {
        guard conversation.messages.filter({ $0.role == .user }).count <= 1 else { return }
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        conversation.title = trimmed.count > 48 ? String(trimmed.prefix(48)) + "…" : trimmed
    }

    private func invalidateSession() {
        let conversationID = conversation.id
        Task { await InferenceEngine.shared.invalidateSession(conversationID: conversationID) }
    }
}
