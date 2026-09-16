import AppIntents
import Foundation
import MLXLMCommon

/// ponytail: runs with the app opened (`openAppWhenRun`). MLX generation
/// on anything past a tiny model can run well past the execution window
/// background App Intents get, so it's more honest to bring the app
/// forward than to risk Siri silently killing a mid-size model mid-reply.
struct AskFaroIntent: AppIntent {
    // Computed, not stored: a `static var` holding a literal is flagged
    // under Swift 6 strict concurrency as unsynchronized global mutable
    // state, even though it never actually changes.
    static var title: LocalizedStringResource { "Preguntar a Faro" }
    static var description: IntentDescription {
        IntentDescription("Envía una pregunta a un modelo de IA que corre en este dispositivo, sin conexión.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Pregunta")
    var prompt: String

    @Parameter(title: "Modelo")
    var modelID: String?

    @Parameter(title: "Instrucciones del sistema")
    var systemPrompt: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Preguntar a Faro: \(\.$prompt)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let resolvedModel = (modelID?.isEmpty == false) ? modelID! : DefaultModel.repoID
        let requestID = UUID()
        var answer = ""

        do {
            let stream = try await InferenceEngine.shared.streamResponse(
                conversationID: requestID,
                modelID: resolvedModel,
                systemPrompt: systemPrompt ?? "",
                history: [],
                settings: .recommended,
                prompt: prompt
            )
            for try await generation in stream {
                if case .chunk(let piece) = generation { answer += piece }
            }
        } catch {
            await InferenceEngine.shared.invalidateSession(conversationID: requestID)
            throw error
        }

        await InferenceEngine.shared.invalidateSession(conversationID: requestID)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

struct FaroShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskFaroIntent(),
            phrases: [
                "Pregunta a \(.applicationName)",
                "Pregúntale a \(.applicationName)"
            ],
            shortTitle: "Preguntar",
            systemImageName: "sparkles"
        )
    }
}
