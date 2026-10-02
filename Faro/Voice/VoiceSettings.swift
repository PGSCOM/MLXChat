import Foundation
import AVFoundation

/// Which engine the voice mode runs on. `.neural` is Faro's own on-device
/// models (see `NeuralVoice`); `.apple` is the original `SFSpeechRecognizer`
/// + `AVSpeechSynthesizer` path, kept for languages the neural models don't
/// cover and for anyone who prefers it (LiveContainer's Apple voice access
/// is unreliable, which is why `.neural` is the default).
enum VoiceEngine: String, CaseIterable {
    case neural
    case apple
}

/// Which neural TTS backend `.neural` speaks with. Both run on FluidAudio
/// (CoreML/Neural Engine) — this only picks the model, not the engine.
enum NeuralTTSBackend: String, CaseIterable {
    /// Kyutai PocketTTS: smaller, streams, has a native voice per language.
    case pocket
    /// Supertonic-3: broader language coverage (31 vs. PocketTTS's 10).
    case supertonic
}

/// Which language the voice mode listens in and which voice answers.
/// Same `UserDefaults` shape as `AppSettings` — two small strings, both
/// empty meaning "decide automatically".
enum VoiceSettings {
    private static let localeKey = "voiceRecognitionLocale"
    private static let voiceKey = "voiceSynthesisVoiceID"
    private static let engineKey = "voiceEngine"
    private static let neuralTTSKey = "voiceNeuralTTS"
    private static let neuralVoiceKey = "voiceNeuralVoiceID"
    /// Everything this enum stores, for `AppReset`.
    static let keys = [localeKey, voiceKey, engineKey, neuralTTSKey, neuralVoiceKey]

    static var engine: VoiceEngine {
        get { UserDefaults.standard.string(forKey: engineKey).flatMap(VoiceEngine.init) ?? .neural }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }

    static var neuralTTS: NeuralTTSBackend {
        get { UserDefaults.standard.string(forKey: neuralTTSKey).flatMap(NeuralTTSBackend.init) ?? .pocket }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: neuralTTSKey) }
    }

    /// A voice name for the chosen neural backend (a PocketTTS voice name
    /// or a Supertonic-3 style id). Empty = pick the best default for the
    /// current language — see `NeuralVoice`.
    static var neuralVoiceID: String {
        get { UserDefaults.standard.string(forKey: neuralVoiceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: neuralVoiceKey) }
    }

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

    /// The two-letter code (`"es"`, `"en"`…) the neural models key off of —
    /// same family (`FluidAudio.Language`, `PocketTtsLanguage`, Supertonic-3's
    /// ISO list) all use plain lowercase ISO 639-1. `NeuralVoice` is the only
    /// file that imports FluidAudio, so this stays a plain string here and
    /// gets turned into the library's own enum cases over there.
    static var neuralLanguageCode: String {
        languageCode(of: recognitionLocale.identifier)
    }

    /// PocketTTS's 6-layer packs only cover es/en/de/it/pt; French ships
    /// 24-layer only. `nil` means PocketTTS has no pack for this language at
    /// all — the caller should fall back to Apple or Supertonic-3.
    /// Matches `PocketTtsLanguage.rawValue` exactly, so `NeuralVoice` just
    /// does `PocketTtsLanguage(rawValue:)` on the result.
    static func pocketLanguagePack(forLanguageCode code: String) -> String? {
        switch code {
        case "es": "spanish"
        case "en": "english"
        case "de": "german"
        case "it": "italian"
        case "pt": "portuguese"
        case "fr": "french_24l"
        default: nil
        }
    }

    /// PocketTTS's native-language voices (recorded in that language, not
    /// English read with an accent) — the best default when the user hasn't
    /// picked one explicitly.
    static func nativePocketVoice(forLanguageCode code: String) -> String {
        switch code {
        case "es": "lola"
        case "fr": "estelle"
        case "de": "juergen"
        case "pt": "rafael"
        case "it": "giovanni"
        default: "alba"
        }
    }

    /// The 26 PocketTTS voice names, shared across every language pack (21
    /// English-trained "literary" voices plus 5 native-language ones — see
    /// FluidAudio's PocketTTS docs).
    static let pocketVoices = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles", "cosette",
        "eponine", "estelle", "eve", "fantine", "george", "giovanni", "jane", "javert",
        "jean", "juergen", "lola", "marius", "mary", "michael", "paul",
        "peter_yearsley", "rafael", "stuart_bell", "vera",
    ]

    /// Supertonic-3's 10 built-in voice styles (`f1`…`f5`, `m1`…`m5`).
    static let supertonicVoices = ["f1", "f2", "f3", "f4", "f5", "m1", "m2", "m3", "m4", "m5"]

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
