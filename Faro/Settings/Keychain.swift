import Foundation
import Security

/// The app's secrets — the local server's token and each MCP server's —
/// as generic passwords under one service. `ThisDeviceOnly` keeps them out
/// of backups and off other devices; `AfterFirstUnlock` still lets a
/// normal launch read them without asking for Face ID.
///
/// ponytail: iOS keeps Keychain items across an uninstall, so a reinstall
/// still finds the old server token (and orphaned MCP ones). "Restablecer
/// Faro" wipes them; a first-launch flag calling `deleteAll()` would cover
/// reinstalls too, if that ever matters.
enum Keychain {
    private static let service = "app.faro.tokens"

    static func string(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces whatever was stored; an empty value just deletes it. False
    /// when the Keychain refused, so the caller can keep the value itself
    /// instead of losing it.
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = baseQuery(for: account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
