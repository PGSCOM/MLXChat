import Foundation
import Observation
import UIKit
import FlyingFox
import FlyingSocks
import MLXLMCommon

/// Local HTTP server exposing an OpenAI-compatible surface
/// (`/v1/models`, `/v1/chat/completions`) so another device on the same
/// network can use this device's model. Shares `InferenceEngine` with
/// the in-app chat, so the two never load the same model twice.
///
/// Reasoning is stripped before it leaves the device: an OpenAI client
/// expects `content` to be the answer, not a `<think>` block glued to the
/// front of it.
///
/// ponytail: text-only for now — `image_url` content parts are parsed
/// but ignored (see `ChatContent`). VLM-over-HTTP is real work (decoding
/// data-URIs into `UserInput.Image`); add it if a client actually needs it.
@Observable
@MainActor
final class APIServer {
    static let shared = APIServer()

    private(set) var isRunning = false
    private(set) var requestLog: [String] = []
    private(set) var pulseToken = 0
    var lastError: String?

    private var server: HTTPServer?
    private var runTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true

        let newServer = HTTPServer(port: UInt16(ServerSettings.port))
        server = newServer

        runTask = Task {
            await Self.configureRoutes(on: newServer, log: Self.appendLog)
            // iOS hangs up the listening socket when the app is
            // suspended; `run()` then throws and must be restarted once
            // the app is foreground again (this loop, tied to the task
            // that's cancelled in `stop()`).
            while !Task.isCancelled {
                do {
                    try await newServer.run()
                    break
                } catch {
                    if Task.isCancelled { break }
                    lastError = error.localizedDescription
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        runTask?.cancel()
        runTask = nil
        let serverToStop = server
        server = nil
        Task { await serverToStop?.stop() }
    }

    nonisolated private static func appendLog(_ line: String) {
        Task { @MainActor in
            APIServer.shared.requestLog.append(line)
            if APIServer.shared.requestLog.count > 50 {
                APIServer.shared.requestLog.removeFirst(APIServer.shared.requestLog.count - 50)
            }
            APIServer.shared.pulseToken += 1
        }
    }

    // MARK: - Routes

    nonisolated private static func configureRoutes(on server: HTTPServer, log: @escaping @Sendable (String) -> Void) async {
        let requiredToken = ServerSettings.bearerToken

        await server.appendRoute("GET /health") { _ in
            HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: Data(#"{"status":"ok"}"#.utf8))
        }

        await server.appendRoute("GET /v1/models") { request in
            guard isAuthorized(request, token: requiredToken) else {
                return HTTPResponse(statusCode: .unauthorized, headers: [.contentType: "application/json"], body: errorBody("Falta el token o es incorrecto."))
            }
            log("GET /v1/models")
            // What this device can actually answer with: everything in the
            // cache, plus the curated ids it would fetch on first use.
            let ids = Set(ModelCacheStore.downloadedIDs())
                .union(CuratedModel.all.map(\.id))
                .union([AppleFoundationModel.id])
            let entries = ids.sorted().map { ModelListResponse.Entry(id: $0) }
            let data = (try? JSONEncoder().encode(ModelListResponse(data: entries))) ?? Data()
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: data)
        }

        await server.appendRoute("POST /v1/chat/completions") { request in
            guard isAuthorized(request, token: requiredToken) else {
                return HTTPResponse(statusCode: .unauthorized, headers: [.contentType: "application/json"], body: errorBody("Falta el token o es incorrecto."))
            }
            log("POST /v1/chat/completions")
            return try await handleChatCompletions(request: request)
        }
    }

    nonisolated private static func isAuthorized(_ request: HTTPRequest, token: String) -> Bool {
        guard !token.isEmpty else { return true }
        guard let header = request.headers[.authorization] else { return false }
        return header == "Bearer \(token)"
    }

    nonisolated private static func errorBody(_ message: String) -> Data {
        (try? JSONEncoder().encode(["error": message])) ?? Data()
    }

    nonisolated private static func handleChatCompletions(request: HTTPRequest) async throws -> HTTPResponse {
        let bodyData = try await request.bodyData
        let payload: ChatCompletionRequest
        do {
            payload = try JSONDecoder().decode(ChatCompletionRequest.self, from: bodyData)
        } catch {
            return HTTPResponse(
                statusCode: .badRequest, headers: [.contentType: "application/json"],
                body: errorBody("JSON inválido: \(error.localizedDescription)")
            )
        }
        guard let lastMessage = payload.messages.last else {
            return HTTPResponse(
                statusCode: .badRequest, headers: [.contentType: "application/json"],
                body: errorBody("El array 'messages' está vacío.")
            )
        }

        let modelID = (payload.model?.isEmpty == false) ? payload.model! : DefaultModel.repoID
        let systemPrompt = payload.messages.first { $0.role == "system" }?.content.plainText ?? ""
        let history = payload.messages.dropLast()
            .filter { $0.role != "system" }
            .map { HistoryTurn(role: MessageRole(rawValue: $0.role) ?? .user, content: $0.content.plainText) }
        let prompt = lastMessage.content.plainText

        let requestID = UUID()
        let completionID = "chatcmpl-\(requestID.uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        var recommended = GenerationSettings.recommended
        if let temperature = payload.temperature { recommended.temperature = temperature }
        if let topP = payload.top_p { recommended.topP = topP }
        if let maxTokens = payload.max_tokens { recommended.maxTokens = maxTokens }

        do {
            let stream = try await InferenceEngine.shared.streamResponse(
                conversationID: requestID, modelID: modelID, systemPrompt: systemPrompt,
                history: Array(history), settings: recommended, prompt: prompt
            )

            if payload.stream == true {
                return streamingResponse(stream: stream, completionID: completionID, created: created, modelID: modelID, requestID: requestID)
            } else {
                var splitter = ThinkTagSplitter()
                var full = ""
                for try await generation in stream {
                    guard case .chunk(let piece) = generation else { continue }
                    let delta = splitter.consume(piece)
                    if delta.contentWasReasoning { full = "" }
                    full += delta.content
                }
                full += splitter.finish().content
                await InferenceEngine.shared.invalidateSession(conversationID: requestID)
                let response = ChatCompletionResponse(
                    id: completionID, created: created, model: modelID,
                    choices: [.init(index: 0, message: .init(role: "assistant", content: full), finish_reason: "stop")]
                )
                let data = try JSONEncoder().encode(response)
                return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: data)
            }
        } catch {
            await InferenceEngine.shared.invalidateSession(conversationID: requestID)
            return HTTPResponse(
                statusCode: .internalServerError, headers: [.contentType: "application/json"],
                body: errorBody(error.localizedDescription)
            )
        }
    }

    nonisolated private static func streamingResponse(
        stream: AsyncThrowingStream<Generation, Error>,
        completionID: String, created: Int, modelID: String, requestID: UUID
    ) -> HTTPResponse {
        let (body, continuation) = AsyncStream<Data>.makeStream()

        Task {
            defer {
                continuation.finish()
                Task { await InferenceEngine.shared.invalidateSession(conversationID: requestID) }
            }
            var splitter = ThinkTagSplitter()

            func send(_ text: String) {
                guard !text.isEmpty else { return }
                let chunk = ChatCompletionChunk(
                    id: completionID, created: created, model: modelID,
                    choices: [.init(index: 0, delta: .init(content: text), finish_reason: nil)]
                )
                if let data = try? JSONEncoder().encode(chunk) {
                    continuation.yield(Data("data: ".utf8) + data + Data("\n\n".utf8))
                }
            }

            do {
                for try await generation in stream {
                    guard case .chunk(let piece) = generation else { continue }
                    // ponytail: a chat template that opens `<think>` inside
                    // the prompt only reveals itself at the closing tag, by
                    // which point these bytes are already on the wire. The
                    // buffered path above corrects itself; this one can't
                    // un-send. Buffer the whole answer here too if a client
                    // ever complains about a leading reasoning block.
                    send(splitter.consume(piece).content)
                }
                send(splitter.finish().content)
                let done = ChatCompletionChunk(
                    id: completionID, created: created, model: modelID,
                    choices: [.init(index: 0, delta: .init(), finish_reason: "stop")]
                )
                if let data = try? JSONEncoder().encode(done) {
                    continuation.yield(Data("data: ".utf8) + data + Data("\n\n".utf8))
                }
                continuation.yield(Data("data: [DONE]\n\n".utf8))
            } catch {
                continuation.yield(Data("data: {\"error\":\"\(error.localizedDescription)\"}\n\n".utf8))
            }
        }

        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
            body: HTTPBodySequence(from: SSEByteStream(chunks: body))
        )
    }
}
