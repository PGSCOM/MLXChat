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
        // The hint text goes to the model only — the saved/shown user
        // message stays clean.
        let systemPrompt = [conversation.effectiveSystemPrompt, effort.systemHint]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let promptForModel = user.promptText + effort.promptSuffix
        let settings = conversation.effectiveGenerationSettings
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
            do {
                let stream = try await InferenceEngine.shared.streamResponse(
                    conversationID: conversationID, modelID: modelID,
                    systemPrompt: systemPrompt, history: history,
                    settings: settings, prompt: promptForModel, imageData: imageData,
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
                            // A bare `</think>` arrived: what already
                            // streamed into the bubble was the model
                            // thinking out loud, so move it.
                            assistantMessage.reasoning =
                                (assistantMessage.reasoning ?? "") + assistantMessage.content
                            assistantMessage.content = ""
                            reasoningStartedAt = reasoningStartedAt ?? streamStartedAt
                        }
                        if !delta.reasoning.isEmpty {
                            if reasoningStartedAt == nil { reasoningStartedAt = .now }
                            if phase != .writing { enter(.thinking) }
                            assistantMessage.reasoning = (assistantMessage.reasoning ?? "") + delta.reasoning
                        }
                        if !delta.content.isEmpty {
                            closeReasoning(on: assistantMessage, startedAt: reasoningStartedAt)
                            enter(.writing)
                            assistantMessage.content += delta.content
                        }
                    case .info(let info):
                        assistantMessage.tokensPerSecond = info.tokensPerSecond
                    default:
                        // Tool calls are resolved inside ChatSession itself
                        // (see InferenceEngine); nothing else reaches here.
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

            // A turn that produced nothing at all (failed load, immediate
            // cancel) would otherwise leave an empty bubble behind forever
            // — fall back to whatever branch was active before it.
            if assistantMessage.content.isEmpty && (assistantMessage.reasoning ?? "").isEmpty {
                conversation.messages.removeAll { $0.id == assistantMessage.id }
                modelContext.delete(assistantMessage)
                conversation.activeLeafID = MessageTree.latestLeaf(from: user, in: conversation.messages).id
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

    func changeModel(to modelID: String) {
        guard modelID != conversation.modelID else { return }
        conversation.modelID = modelID
        // Every model pick in the app funnels through here, so this is the
        // one place that has to remember it for the next new conversation.
        AppSettings.lastModelID = modelID
        try? modelContext.save()
        invalidateSession()
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

    private func closeReasoning(on message: ChatMessage, startedAt: Date?) {
        guard let startedAt, message.reasoningSeconds == nil else { return }
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
