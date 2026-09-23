import Foundation
import AVFoundation

/// Which language the voice mode listens in and which voice answers.
/// Same `UserDefaults` shape as `AppSettings` — two small strings, both
/// empty meaning "decide automatically".
enum VoiceSettings {
    private static let localeKey = "voiceRecognitionLocale"
    private static let voiceKey = "voiceSynthesisVoiceID"
    /// Everything this enum stores, for `AppReset`.
    static let keys = [localeKey, voiceKey]

    /// An ICU identifier, as `SFSpeechRecognizer.supportedLocales()` hands
    /// them out. Empty = follow the system.
    static var recognitionLocaleID: String {
        get { UserDefaults.standard.string(forKey: localeKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: localeKey) }
    }

    /// An `AVSpeechSynthesisVoice.identifier`. Empty = pick the best
    /// installed voice for the language.
    static var synthesisVoiceID: String {
        get { UserDefaults.standard.string(forKey: voiceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }

    static var recognitionLocale: Locale {
        recognitionLocaleID.isEmpty ? .current : Locale(identifier: recognitionLocaleID)
    }

    /// BCP-47 (`es-ES`), which is what every `AVSpeechSynthesis*` API
    /// wants — `Locale.identifier` alone is ICU (`es_ES`) and is rejected.
    static var speechLanguageTag: String {
        recognitionLocale.identifier(.bcp47)
    }

    /// The chosen voice, else the best-quality installed one for the
    /// language, else nil (the synthesizer falls back to the system voice).
    static func voice() -> AVSpeechSynthesisVoice? {
        // A picked voice can be uninstalled later, and `init?(identifier:)`
        // then returns nil — fall through to the automatic pick instead of
        // going silent.
        if !synthesisVoiceID.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: synthesisVoiceID) {
            return chosen
        }
        return bestVoice(for: speechLanguageTag) ?? AVSpeechSynthesisVoice(language: speechLanguageTag)
    }

    /// Ranked by `quality.rawValue`, which orders premium over enhanced
    /// over default without naming a case — the premium voices simply
    /// don't appear in `speechVoices()` until the user installs them.
    static func bestVoice(for languageTag: String) -> AVSpeechSynthesisVoice? {
        installedVoices(for: languageTag).max { $0.quality.rawValue < $1.quality.rawValue }
    }

    static func installedVoices(for languageTag: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { matches(voiceLanguage: $0.language, preferred: languageTag) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    /// Exact tag first, then same language in another region — a Mexican
    /// voice answers a Spanish request long before English should.
    static func matches(voiceLanguage: String, preferred: String) -> Bool {
        guard !preferred.isEmpty else { return true }
        if voiceLanguage.caseInsensitiveCompare(preferred) == .orderedSame { return true }
        return languageCode(of: voiceLanguage) == languageCode(of: preferred)
    }

    private static func languageCode(of tag: String) -> String {
        let separators = CharacterSet(charactersIn: "-_")
        let head = tag.components(separatedBy: separators).first ?? tag
        return head.lowercased()
    }

    /// What to call a quality in the picker. Plain text on purpose — a
    /// tinted chip per row is exactly the component-kit look to avoid.
    static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality.rawValue {
        case 3...: " · Premium"
        case 2: " · Mejorada"
        default: ""
        }
    }
}
