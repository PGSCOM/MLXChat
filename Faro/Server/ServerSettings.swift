import Foundation

/// Persisted server configuration. The server itself always starts OFF
/// on launch — the user opts in each time, which is also the simpler,
/// more private default (no silently-running network service).
enum ServerSettings {
    private static let portKey = "serverPort"
    private static let tokenKey = "serverBearerToken"

    static var port: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: portKey)
            return value == 0 ? 8080 : value
        }
        set { UserDefaults.standard.set(newValue, forKey: portKey) }
    }

    /// Generated once, reused after that, editable by the user.
    static var bearerToken: String {
        get {
            if let existing = UserDefaults.standard.string(forKey: tokenKey), !existing.isEmpty {
                return existing
            }
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: tokenKey)
            return generated
        }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: portKey)
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }
}
