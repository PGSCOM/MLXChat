import Foundation

/// Persisted server configuration. The server itself always starts OFF
/// on launch — the user opts in each time, which is also the simpler,
/// more private default (no silently-running network service).
enum ServerSettings {
    private static let portKey = "serverPort"
    private static let tokenKey = "serverBearerToken"
    /// Everything this enum keeps in `UserDefaults` (the token only until
    /// it moves to the Keychain), for `AppReset`.
    static let keys = [portKey, tokenKey]

    static var port: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: portKey)
            return value == 0 ? 8080 : value
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }

    /// Generated once, reused after that, kept in the Keychain. A token
    /// saved in `UserDefaults` before that is carried over rather than
    /// replaced, so devices already using it keep working.
    static var bearerToken: String {
        if let stored = Keychain.string(for: tokenKey) { return stored }
        let legacy = UserDefaults.standard.string(forKey: tokenKey) ?? ""
        let token = legacy.isEmpty ? UUID().uuidString : legacy
        if Keychain.set(token, for: tokenKey) {
            UserDefaults.standard.removeObject(forKey: tokenKey)
        } else {
            // Without a Keychain it stays put: minting a new token on
            // every read would lock every client out.
            UserDefaults.standard.set(token, forKey: tokenKey)
        }
        return token
    }
}
