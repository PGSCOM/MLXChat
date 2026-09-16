import Foundation

/// App-wide defaults, applied to new conversations. Kept in
/// `UserDefaults` since it's a single small string — no SwiftData model
/// needed for this.
enum AppSettings {
    private static let systemPromptKey = "defaultSystemPrompt"

    static var defaultSystemPrompt: String {
        get { UserDefaults.standard.string(forKey: systemPromptKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: systemPromptKey) }
    }
}
