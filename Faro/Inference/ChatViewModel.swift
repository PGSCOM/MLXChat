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
    /// The user message being edited, if any — `send()` adds its
    /// replacement as a sibling instead of appending at the end.
    private(set) var editingMessage: ChatMessage?

    private var generateTask: Task<Void, Never>?

    init(conversation: Conversation, modelContext: SwiftData.ModelContext) {
        self.conversation = conversation
        self.modelContext = modelContext
        refreshCapabilities()

        // First open under branching: thread the old flat history into one
        // chain and point the active leaf at its end. A conversation with
        // no messages yet just stays at nil — `send()` handles that.
        if conversation.activeLeafID == nil, let last = conversation.messages.max(by: { $0.createdAt < $1.createdAt }) {
            MessageTree.threadLegacy(conversation.messages)
            conversation.activeLeafID = last.id
            try? modelContext.save()
        }
    }

    var isGenerating: Bool { phase != .idle }

    /// The branch currently on screen, root to the active leaf.
    var messages: [ChatMessage] {
        guard let leafID = conversation.activeLeafID else { return [] }
        return MessageTree.path(to: leafID, in: conversation.messages)
    }

    /// Every version of `message` (itself included), for the branch
    /// selector. A message with no siblings returns just itself.
    func siblings(of message: ChatMessage) -> [ChatMessage] {
        MessageTree.siblings(of: message, in: conversation.messages)
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

    /// Loads a user message into the composer for editing: its text, and
    /// its attachment/image so they can be kept, swapped or dropped before
    /// resending. `send()` then adds the result as a sibling of `message`.
    func beginEditing(_ message: ChatMessage) {
        guard !isGenerating, message.role == .user else { return }
        editingMessage = message
        draft = message.content
        if let name = message.attachmentName, let text = message.attachmentText {
            pendingAttachment = ExtractedAttachment(fileName: name, text: text, wasTruncated: false)
        } else {
            pendingAttachment = nil
        }
        pendingImageData = message.imageData
    }

    func cancelEditing() {
        editingMessage = nil
        draft = ""
        pendingAttachment = nil
        pendingImageData = nil
    }

    /// Switches to another version of `message`: `offset` is +1/-1 for
    /// next/previous among its siblings. Always lands on the newest reply
    /// down whichever branch it lands on.
    func showSibling(of message: ChatMessage, offset: Int) {
        guard !isGenerating else { return }
        let group = siblings(of: message)
        guard let index = group.firstIndex(where: { $0.id == message.id }) else { return }
        let target = index + offset
        guard group.indices.contains(target) else { return }
        conversation.activeLeafID = MessageTree.latestLeaf(from: group[target], in: conversation.messages).id
        try? modelContext.save()
        invalidateSession()
    }

    func send() {
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || pendingAttachment != nil || pendingImageData != nil, !isGenerating else { return }
        draft = ""
        errorMessage = nil

        let editing = editingMessage
        editingMessage = nil

        let defaultText = pendingAttachment != nil ? "Resume este archivo." : "Describe esta imagen."
        let userText = typed.isEmpty ? defaultText : typed
        let attachmentName = pendingAttachment?.fileName
        let attachmentText = pendingAttachment.map { attachment in
            attachment.text + (attachment.wasTruncated ? "\n\n[el archivo se truncó por longitud]" : "")
        }
        pendingAttachment = nil
        let imageData = pendingImageData
        pendingImageData = nil

        // Editing adds a sibling under the edited message's own parent;
        // otherwise this continues whatever branch is on screen.
        let parentID = editing?.parentID ?? conversation.activeLeafID
        let promptHistory = history(before: parentID)

        let userMessage = ChatMessage(
            role: .user, content: userText, imageData: imageData,
            attachmentName: attachmentName, attachmentText: attachmentText, parentID: parentID
        )
        userMessage.conversation = conversation
        modelContext.insert(userMessage)
        conversation.messages.append(userMessage)
        nameConversationIfNeeded(from: userText)

        // Editing rebuilds the model's context from scratch (the old
        // session still has the superseded turn baked in); a plain send
        // just continues the live session.
        startTurn(user: userMessage, history: promptHistory, freshSession: editing != nil)
    }

    /// Adds a new reply under `assistantMessage`'s same user turn, as a
    /// sibling — the original reply is kept, not overwritten, and stays
    /// reachable through the branch switcher. Passing `modelID` tries that
    /// model for this one branch only — it does *not* change what the
    /// conversation goes on to use, so switching back to an earlier branch
    /// still continues with whatever model answered it.
    func regenerate(_ assistantMessage: ChatMessage, with modelID: String? = nil) {
        guard !isGenerating, assistantMessage.role == .assistant,
              let parentID = assistantMessage.parentID,
              let userMessage = conversation.messages.first(where: { $0.id == parentID })
        else { return }

        errorMessage = nil
        startTurn(user: userMessage, history: history(before: userMessage.parentID), modelID: modelID, freshSession: true)
    }

    /// Everything shared between a plain send and a regenerate: creates
    /// the assistant placeholder as a child of `user`, points the active
    /// branch at it, and streams the reply in. `modelID` overrides the
    /// conversation's own model for just this turn (a "relanzar con otro
    /// modelo" branch); omitted, it uses whatever the conversation is
    /// already set to. `freshSession` forces the live `ChatSession` to be
    /// rebuilt first — required whenever `history` doesn't match what the
    /// session already has (editing, regenerating, switching branches),
    /// not just appended to.
    private func startTurn(user: ChatMessage, history: [HistoryTurn], modelID overrideModelID: String? = nil, freshSession: Bool) {
        let modelID = overrideModelID ?? conversation.modelID

        let assistantMessage = ChatMessage(role: .assistant, content: "", parentID: user.id)
        assistantMessage.modelID = modelID
        assistantMessage.conversation = conversation
        modelContext.insert(assistantMessage)
        conversation.messages.append(assistantMessage)
        conversation.activeLeafID = assistantMessage.id
        try? modelContext.save()

        enter(.preparing)
        streamingMessageID = assistantMessage.id

        let conversationID = conversation.id
        let effort = conversation.thinkingEffort
        let style = conversation.responseStyle ?? Personalization.style
        let systemPrompt = [
            Personalization.preamble(style: style),
            SkillStore.alwaysOnInstructions(),
            conversation.effectiveSystemPrompt,
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let settings = conversation.effectiveGenerationSettings
        let prompt = user.promptText
        let imageData = user.imageData

        let downloadCoordinator = ModelDownloadCoordinator.shared
        // Apple's model is already on the device: there is no download or
        // paging-in to report, so no load band either.
        if !AppleFoundationModel.isAppleFoundation(modelID) {
            downloadCoordinator.beginLoad(id: modelID)
        }

        generateTask = Task {
            // Ordered before the stream starts, so the session is never
            // rebuilt out from under a request already in flight.
            if freshSession {
                await InferenceEngine.shared.invalidateSession(conversationID: conversationID)
            }
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
            // cancel) would otherwise leave an empty bubble behind forever
            // — fall back to whatever branch was active before it. The live
            // session may already hold this turn's prompt (and, after a
            // relaunch, only the history up to it), so drop it: the next
            // turn rebuilds from the branch actually on screen.
            if assistantMessage.content.isEmpty && (assistantMessage.reasoning ?? "").isEmpty {
                conversation.messages.removeAll { $0.id == assistantMessage.id }
                modelContext.delete(assistantMessage)
                conversation.activeLeafID = MessageTree.latestLeaf(from: user, in: conversation.messages).id
                await InferenceEngine.shared.invalidateSession(conversationID: conversationID)
            }

            streamingMessageID = nil
            enter(.idle)
            try? modelContext.save()
        }
    }

    /// The history to prompt with: everything on the branch up to (but not
    /// including) the turn now being answered.
    private func history(before parentID: UUID?) -> [HistoryTurn] {
        guard let parentID, let parent = conversation.messages.first(where: { $0.id == parentID }) else { return [] }
        return MessageTree.path(to: parent.id, in: conversation.messages)
            .filter { !($0.role == .assistant && $0.content.isEmpty) }
            .map { HistoryTurn(role: $0.role, content: $0.promptText, imageData: $0.imageData) }
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
