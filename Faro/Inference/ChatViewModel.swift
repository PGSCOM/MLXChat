import Foundation
import Observation
import SwiftData
import MLXLMCommon

@Observable
@MainActor
final class ChatViewModel {
    let conversation: Conversation
    private let modelContext: SwiftData.ModelContext

    private(set) var isGenerating = false
    private(set) var tokensPerSecond: Double = 0
    var errorMessage: String?
    var draft = ""
    private(set) var pendingAttachment: ExtractedAttachment?
    private(set) var pendingImageData: Data?

    private var generateTask: Task<Void, Never>?

    init(conversation: Conversation, modelContext: SwiftData.ModelContext) {
        self.conversation = conversation
        self.modelContext = modelContext
    }

    var messages: [ChatMessage] {
        conversation.messages.sorted { $0.createdAt < $1.createdAt }
    }

    func attach(url: URL) {
        do {
            pendingAttachment = try AttachmentExtractor.extractText(from: url)
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
        // and the empty assistant placeholder is filled in place as it streams.
        let history = messages.map { HistoryTurn(role: $0.role, content: $0.content, imageData: $0.imageData) }

        let userMessage = ChatMessage(role: .user, content: text, imageData: imageData)
        userMessage.conversation = conversation
        modelContext.insert(userMessage)
        conversation.messages.append(userMessage)

        let assistantMessage = ChatMessage(role: .assistant, content: "")
        assistantMessage.conversation = conversation
        modelContext.insert(assistantMessage)
        conversation.messages.append(assistantMessage)

        isGenerating = true
        let conversationID = conversation.id
        let modelID = conversation.modelID
        let effort = conversation.thinkingEffort
        // The hint text goes to the model only — the saved/shown user
        // message (`text`, already persisted above) stays clean.
        let systemPrompt = [conversation.systemPrompt, effort.systemHint]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let promptForModel = text + effort.promptSuffix
        let settings = conversation.effectiveGenerationSettings

        let downloadCoordinator = ModelDownloadCoordinator.shared
        downloadCoordinator.beginLoad(id: modelID)

        generateTask = Task {
            var splitter = ThinkTagSplitter()
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
                for try await generation in stream {
                    switch generation {
                    case .chunk(let piece):
                        let delta = splitter.consume(piece)
                        if !delta.reasoning.isEmpty {
                            assistantMessage.reasoning = (assistantMessage.reasoning ?? "") + delta.reasoning
                        }
                        if !delta.content.isEmpty {
                            assistantMessage.content += delta.content
                        }
                    case .info(let info):
                        tokensPerSecond = info.tokensPerSecond
                        assistantMessage.tokensPerSecond = info.tokensPerSecond
                    default:
                        // Tool calls are resolved inside ChatSession itself
                        // (see InferenceEngine); nothing else reaches here.
                        break
                    }
                }
            } catch is CancellationError {
                // User cancelled: keep whatever streamed so far.
                downloadCoordinator.finishLoad(id: modelID)
            } catch {
                errorMessage = error.localizedDescription
                downloadCoordinator.finishLoad(id: modelID)
            }

            // Whatever the splitter was still holding back as possible
            // tag-boundary lookahead is now final — release it.
            let tail = splitter.finish()
            if !tail.reasoning.isEmpty {
                assistantMessage.reasoning = (assistantMessage.reasoning ?? "") + tail.reasoning
            }
            if !tail.content.isEmpty {
                assistantMessage.content += tail.content
            }

            try? modelContext.save()
            isGenerating = false
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

    func changeModel(to modelID: String) {
        guard modelID != conversation.modelID else { return }
        conversation.modelID = modelID
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

    private func invalidateSession() {
        let conversationID = conversation.id
        Task { await InferenceEngine.shared.invalidateSession(conversationID: conversationID) }
    }
}
