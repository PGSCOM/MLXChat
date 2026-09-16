import Foundation
import SwiftData

@Model
final class MCPServerConfig {
    var id: UUID
    var name: String
    var url: String
    var bearerToken: String
    var isEnabled: Bool = false
    /// The confirmation dialog (data leaves the device once enabled) is
    /// only shown the first time a server is turned on.
    var hasBeenConfirmed: Bool = false
    var createdAt: Date

    init(name: String, url: String, bearerToken: String = "") {
        id = UUID()
        self.name = name
        self.url = url
        self.bearerToken = bearerToken
        createdAt = .now
    }

    var snapshot: MCPServerConfigSnapshot {
        MCPServerConfigSnapshot(id: id, url: url, bearerToken: bearerToken)
    }
}

/// Sendable copy of the fields `MCPConnectionManager` (an actor) needs —
/// `MCPServerConfig` itself is a SwiftData model and can't cross actors.
struct MCPServerConfigSnapshot: Sendable {
    let id: UUID
    let url: String
    let bearerToken: String
}
