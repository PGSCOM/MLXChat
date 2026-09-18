import Foundation
import FoundationModels
import MLXLMCommon

/// Apple's on-device model, wrapped to look like every other backend:
/// same `HistoryTurn` input, same `AsyncThrowingStream<Generation, Error>`
/// output, so `InferenceEngine` only has to pick a branch.
///
/// Every reference to `FoundationModels` in the app lives in this file. If
/// a signature here turns out to be wrong, exactly one file fails to build.
///
/// `@MainActor` rather than an actor on purpose: `SystemLanguageModel` and
/// `LanguageModelSession` are the observable types Apple's own samples
/// drive straight from a view model, and pinning them to one known
/// isolation avoids guessing at their `Sendable` conformance under strict
/// concurrency. The work itself is `async`, so nothing blocks the UI.
@MainActor
final class AppleFoundationEngine {
    static let shared = AppleFoundationEngine()

    private var sessions: [UUID: LanguageModelSession] = [:]

    private init() {}

    func invalidateSession(conversationID: UUID) {
        sessions[conversationID] = nil
    }

    /// ponytail: one `.chunk` for the whole answer instead of streaming.
    /// `streamResponse` emits cumulative snapshots rather than deltas, and
    /// the snapshot type for a plain `String` answer isn't the same across
    /// SDK revisions — none of which can be compiled on this machine.
    /// `respond(to:)` is the stable surface. Upgrade path: swap in
    /// `streamResponse` and yield the difference against what was already
    /// emitted, once it can be checked against a real SDK.
    func streamResponse(
        conversationID: UUID,
        systemPrompt: String,
        history: [HistoryTurn],
        settings: GenerationSettings,
        prompt: String,
        imageData: Data?
    ) throws -> AsyncThrowingStream<Generation, Error> {
        guard imageData == nil else { throw AppleFoundationError.noVision }
        try Self.checkAvailability()
        // Built here, not inside the stream, so an unusable model reports
        // itself to the caller instead of failing silently mid-turn.
        _ = session(conversationID: conversationID, systemPrompt: systemPrompt, history: history)

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let text = try await self.answer(
                        conversationID: conversationID, settings: settings, prompt: prompt
                    )
                    continuation.yield(.chunk(text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func answer(
        conversationID: UUID, settings: GenerationSettings, prompt: String
    ) async throws -> String {
        guard let session = sessions[conversationID] else { throw AppleFoundationError.noSession }
        let options = GenerationOptions(
            temperature: settings.temperature,
            maximumResponseTokens: settings.maxTokens
        )
        return try await session.respond(to: prompt, options: options).content
    }

    /// A session carries its own transcript, so prior turns are replayed
    /// only when one is created — same lifecycle as the MLX `ChatSession`.
    private func session(
        conversationID: UUID, systemPrompt: String, history: [HistoryTurn]
    ) -> LanguageModelSession {
        if let existing = sessions[conversationID] { return existing }
        let instructions = Self.instructions(systemPrompt: systemPrompt, history: history)
        let session = LanguageModelSession(instructions: instructions)
        sessions[conversationID] = session
        return session
    }

    /// The framework takes instructions as one string and grows its own
    /// transcript from there, so prior turns are folded into the
    /// instructions rather than replayed as messages.
    private static func instructions(systemPrompt: String, history: [HistoryTurn]) -> String {
        var parts: [String] = []
        if !systemPrompt.isEmpty { parts.append(systemPrompt) }
        let transcript = history
            .filter { !$0.content.isEmpty }
            .map { turn in
                switch turn.role {
                case .user: "Usuario: \(turn.content)"
                case .assistant: "Asistente: \(turn.content)"
                case .system: turn.content
                }
            }
        if !transcript.isEmpty {
            parts.append("Conversación previa:\n" + transcript.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Deliberately not switching over `UnavailableReason`'s cases: their
    /// names can't be verified here, while `String(describing:)` compiles
    /// whatever they turn out to be.
    private static func checkAvailability() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw AppleFoundationError.unavailable(String(describing: reason))
        }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
}

enum AppleFoundationError: LocalizedError {
    case unavailable(String)
    case noVision
    case noSession

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            "Apple Intelligence no está disponible en este dispositivo (\(reason)). Actívalo en Ajustes o elige otro modelo."
        case .noVision:
            "El modelo de Apple solo entiende texto. Elige un modelo con visión para enviar imágenes."
        case .noSession:
            "No se pudo abrir una sesión con el modelo de Apple."
        }
    }
}
