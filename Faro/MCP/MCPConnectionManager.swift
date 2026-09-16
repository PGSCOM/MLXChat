import Foundation
import MCP
import MLXLMCommon

struct MCPToolSummary: Sendable, Hashable {
    let name: String
    let description: String
}

enum MCPClientError: LocalizedError {
    case invalidURL
    case unknownTool(String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL de servidor MCP no válida."
        case .unknownTool(let name): return "Herramienta desconocida: \(name)."
        case .toolFailed(let message): return message
        }
    }
}

/// Owns every connected MCP server. Tool calls from `ChatSession` are
/// fail-closed by MLXLMCommon's own design (only names present in the
/// schemas handed to `ChatSession(tools:)` ever reach `dispatch`), so
/// this only needs to route an already-validated call to its server.
actor MCPConnectionManager {
    static let shared = MCPConnectionManager()

    private var clients: [UUID: Client] = [:]
    private var toolOwners: [String: UUID] = [:]
    private var cachedSpecs: [UUID: [ToolSpec]] = [:]

    private init() {}

    @discardableResult
    func connect(_ config: MCPServerConfigSnapshot) async throws -> [MCPToolSummary] {
        let client: Client
        if let existing = clients[config.id] {
            client = existing
        } else {
            guard let url = URL(string: config.url) else { throw MCPClientError.invalidURL }
            let token = config.bearerToken
            let transport = HTTPClientTransport(
                endpoint: url,
                requestModifier: { request in
                    guard !token.isEmpty else { return request }
                    var modified = request
                    modified.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    return modified
                }
            )
            let newClient = Client(name: "Faro", version: "1.0")
            _ = try await newClient.connect(transport: transport)
            clients[config.id] = newClient
            client = newClient
        }

        let (tools, _) = try await client.listTools()
        cachedSpecs[config.id] = tools.map { MCPToolBridge.toolSpec(for: $0) }
        toolOwners = toolOwners.filter { $0.value != config.id }
        for tool in tools { toolOwners[tool.name] = config.id }
        return tools.map { MCPToolSummary(name: $0.name, description: $0.description ?? "") }
    }

    func disconnect(_ id: UUID) {
        clients[id] = nil
        cachedSpecs[id] = nil
        toolOwners = toolOwners.filter { $0.value != id }
    }

    /// Combined schemas from every currently connected server — handed
    /// straight to `ChatSession(tools:)`.
    func enabledToolSpecs() -> [ToolSpec] {
        Array(cachedSpecs.values.joined())
    }

    func dispatch(_ call: ToolCall) async throws -> String {
        guard let ownerID = toolOwners[call.function.name], let client = clients[ownerID] else {
            throw MCPClientError.unknownTool(call.function.name)
        }
        let arguments = MCPToolBridge.mcpArguments(from: call.function.arguments)
        let (content, isError) = try await client.callTool(name: call.function.name, arguments: arguments)
        let text = content.compactMap { item -> String? in
            if case .text(let value, _, _) = item { return value }
            return nil
        }.joined(separator: "\n")

        if isError == true {
            throw MCPClientError.toolFailed(text.isEmpty ? "La herramienta devolvió un error." : text)
        }
        return text
    }
}
