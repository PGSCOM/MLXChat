import Foundation
import SwiftData

@Model
final class MCPServerConfig {
    var id: UUID
    var name: String
    var url: String
    /// Where tokens lived before the Keychain. Only `token` touches it
    /// now, and it stays empty unless the Keychain ever refuses one.
    var bearerToken: String
    var isEnabled: Bool = false
    /// The confirmation dialog (data leaves the device once enabled) is
    /// only shown the first time a server is turned on.
    var hasBeenConfirmed: Bool = false
    var createdAt: Date

    init(name: String, url: String, token: String = "") {
        id = UUID()
        self.name = name
        self.url = url
        bearerToken = ""
        createdAt = .now
        self.token = token
    }

    /// Lives in the Keychain, not the store: a credential for someone
    /// else's server has no place in a plain database file or a backup.
    /// Setting it empty deletes it.
    var token: String {
        get { Keychain.string(for: keychainAccount) ?? bearerToken }
        // Kept in the store only if the Keychain refuses it — losing the
        // token outright would be worse.
        set { bearerToken = Keychain.set(newValue, for: keychainAccount) ? "" : newValue }
    }

    /// Moves a token saved before the Keychain into it. Run at launch.
    func moveTokenToKeychain() {
        if !bearerToken.isEmpty { token = bearerToken }
    }

    private var keychainAccount: String { "mcp.\(id.uuidString)" }

    var snapshot: MCPServerConfigSnapshot {
        MCPServerConfigSnapshot(id: id, url: url, bearerToken: token)
    }
}

/// Sendable copy of the fields `MCPConnectionManager` (an actor) needs —
/// `MCPServerConfig` itself is a SwiftData model and can't cross actors.
struct MCPServerConfigSnapshot: Sendable {
    let id: UUID
    let url: String
    let bearerToken: String
}
