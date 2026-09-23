import Foundation

/// App-wide defaults, applied to new conversations. Kept in
/// `UserDefaults` since these are small strings — no SwiftData model
/// needed for them.
enum AppSettings {
    private static let systemPromptKey = "defaultSystemPrompt"
    private static let lastModelKey = "lastModelID"
    /// Everything this enum stores, for `AppReset`.
    static let keys = [systemPromptKey, lastModelKey]

    static var defaultSystemPrompt: String {
        get { UserDefaults.standard.string(forKey: systemPromptKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: systemPromptKey) }
    }

    /// The last model the user actually picked. New conversations start
    /// here instead of always falling back to the smallest curated model.
    /// Empty means nothing was ever chosen.
    static var lastModelID: String {
        get { UserDefaults.standard.string(forKey: lastModelKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastModelKey) }
    }
}
