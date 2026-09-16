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

    private var generateTask: Task<Void, Never>?

    init(conversation: Conversation, modelContext: SwiftData.ModelContext) {
        self.conversation = conversation
        self.modelContext = modelContext
    }

    var messages: [ChatMessage] {
        conversation.messages.sorted { $0.createdAt < $1.createdAt }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        draft = ""
        errorMessage = nil

        // History excludes this turn: the user text goes in as the prompt,
        // and the empty assistant placeholder is filled in place as it streams.
        let history = messages.map { HistoryTurn(role: $0.role, content: $0.content) }

        let userMessage = ChatMessage(role: .user, content: text)
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
        let systemPrompt = conversation.systemPrompt

        generateTask = Task {
            var splitter = ThinkTagSplitter()
            do {
                let stream = try await InferenceEngine.shared.streamResponse(
                    conversationID: conversationID, modelID: modelID,
                    systemPrompt: systemPrompt, history: history, prompt: text)
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
                        // Tool calls arrive with Fase 5 (cliente MCP); until
                        // then anything other than text/stats is ignored.
                        break
                    }
                }
            } catch is CancellationError {
                // User cancelled: keep whatever streamed so far.
            } catch {
                errorMessage = error.localizedDescription
            }
            try? modelContext.save()
            isGenerating = false
        }
    }

    func cancel() {
        generateTask?.cancel()
    }
}
