import Foundation
import FluidAudio

/// Faro's own on-device speech engine: FluidAudio's Parakeet TDT v3 for
/// listening, PocketTTS or Supertonic-3 for speaking — all CoreML,
/// Neural-Engine-resident, Apache-2.0 with no GPL/espeak dependency. This is
/// the only file in the app that imports FluidAudio; `VoiceSession` and
/// `VoiceSettings` only ever pass plain Swift types across the boundary
/// (mirrors how `HistoryTurn` keeps MLXLMCommon out of everything but
/// `InferenceEngine`).
///
/// A single actor because the three model families share one job: don't let
/// the mic-tap thread or the chat UI touch a `MLModel` directly, and don't
/// let two callers load the same multi-hundred-MB model twice.
actor NeuralVoice {
    static let shared = NeuralVoice()

    /// Everything downloads here so `AppReset` can wipe it with one
    /// `removeItem`, the same idea as `HubCache` for the LLM weights.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Voz", isDirectory: true)
    }()

    static func deleteModels() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Pure support checks — no model state, safe to call from the main
    /// actor before deciding whether this turn even needs `prepare()`.
    /// `VoiceSession` falls back to the Apple engine when either half (the
    /// language, or the chosen TTS backend for it) comes back `false`.
    nonisolated static func supportsListening(languageCode: String) -> Bool {
        Language(rawValue: languageCode) != nil
    }

    nonisolated static func supportsSpeaking(languageCode: String, tts: NeuralTTSBackend) -> Bool {
        switch tts {
        case .pocket:
            guard let pack = VoiceSettings.pocketLanguagePack(forLanguageCode: languageCode) else { return false }
            return PocketTtsLanguage(rawValue: pack) != nil
        case .supertonic:
            return Supertonic3Constants.availableLanguages.contains(languageCode)
        }
    }

    private var asr: AsrManager?
    private var pocket: PocketTtsManager?
    private var pocketLanguagePack: String?
    private var supertonic: Supertonic3Manager?
    private var supertonicVoice: (name: String, style: Supertonic3VoiceStyle)?

    /// Downloads (first run only) and loads whatever the current settings
    /// need. Safe to call every time the voice sheet opens: each backend
    /// short-circuits once it already has the right language/model loaded.
    func prepare(
        languageCode: String,
        tts: NeuralTTSBackend,
        voiceID: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await prepareASR(progress: { progress($0 * 0.5) })
        switch tts {
        case .pocket:
            try await preparePocket(languageCode: languageCode, progress: { progress(0.5 + $0 * 0.5) })
        case .supertonic:
            let voiceName = voiceID.isEmpty ? Supertonic3Voice.default.rawValue : voiceID
            try await prepareSupertonic(voiceName: voiceName, progress: { progress(0.5 + $0 * 0.5) })
        }
    }

    /// Parakeet TDT v3 is one multilingual model — loaded once, ever, and
    /// reused across every language it supports (the language only steers
    /// token filtering at transcribe time).
    private func prepareASR(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard asr == nil else { return }
        let models = try await AsrModels.downloadAndLoad(
            to: Self.directory,
            version: .v3,
            progressHandler: { progress($0.fractionCompleted) }
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    private func preparePocket(languageCode: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let pack = VoiceSettings.pocketLanguagePack(forLanguageCode: languageCode),
              let language = PocketTtsLanguage(rawValue: pack)
        else {
            throw NeuralVoiceError.unsupportedLanguage
        }
        guard pocketLanguagePack != pack else { return }
        // int8: FlowLM (the largest file) quantized, ~28% smaller on disk —
        // see FluidAudio's PocketTTS docs on why only that stage is safe to
        // quantize. `ensureModels` first so download progress is visible;
        // `initialize()` then finds everything present and just loads it.
        try await PocketTtsResourceDownloader.ensureModels(
            language: language,
            directory: Self.directory,
            precision: .int8,
            progressHandler: { progress($0.fractionCompleted) }
        )
        // The voice is picked per-call in `speak(voiceID:)`, not baked in
        // here, so switching voices never needs a model reload.
        let manager = PocketTtsManager(language: language, directory: Self.directory, precision: .int8)
        try await manager.initialize()
        pocket = manager
        pocketLanguagePack = pack
        // Only one TTS backend needs to be resident at a time; the other's
        // multi-hundred-MB models are dead weight competing with the LLM.
        supertonic = nil
        supertonicVoice = nil
    }

    /// `Supertonic3Manager.downloadAndCreate` has no progress callback and
    /// the variant string it downloads (`downloadVariant`) isn't public, so
    /// unlike ASR/PocketTTS this can't report incremental progress — it
    /// just resolves once the (one-time, ~400 MB) download and load finish.
    private func prepareSupertonic(voiceName: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let voice = Supertonic3Voice(name: voiceName) else {
            throw NeuralVoiceError.unknownVoice
        }
        if supertonic == nil {
            supertonic = try await Supertonic3Manager.downloadAndCreate(cacheDirectory: Self.directory)
        }
        if supertonicVoice?.name != voice.rawValue {
            let style = try await Supertonic3ResourceDownloader.loadVoiceStyle(voice, directory: Self.directory)
            supertonicVoice = (voice.rawValue, style)
        }
        progress(1)
        pocket = nil
        pocketLanguagePack = nil
    }

    /// Transcribes one utterance. `samples` are the mic's own native rate —
    /// FluidAudio's `AudioConverter` resamples to the 16kHz mono the model
    /// wants, so `VoiceSession` never has to touch that itself.
    func transcribe(samples: [Float], sampleRate: Double, languageCode: String) async throws -> String {
        guard let asr else { throw NeuralVoiceError.notReady }
        let resampled = try AudioConverter(debug: false).resample(samples, from: sampleRate)
        var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(resampled, decoderState: &decoderState, language: Language(rawValue: languageCode))
        return result.text
    }

    /// Synthesizes `text` and returns it as a single block of samples at the
    /// backend's native rate — simpler than streaming for turns this short,
    /// and it means `VoiceSession` only ever deals with one playback path.
    func speak(_ text: String, tts: NeuralTTSBackend, languageCode: String, voiceID: String) async throws -> (samples: [Float], sampleRate: Double) {
        switch tts {
        case .pocket:
            guard let pocket else { throw NeuralVoiceError.notReady }
            let voice = voiceID.isEmpty ? VoiceSettings.nativePocketVoice(forLanguageCode: languageCode) : voiceID
            var samples: [Float] = []
            for try await frame in try await pocket.synthesizeStreaming(text: text, voice: voice) {
                samples.append(contentsOf: frame.samples)
            }
            return (samples, 24_000)
        case .supertonic:
            guard let supertonic, let voice = supertonicVoice else { throw NeuralVoiceError.notReady }
            let (samples, _) = try await supertonic.synthesize(
                text: text,
                language: languageCode,
                style: voice.style
            )
            return (samples, Double(Supertonic3Constants.sampleRate))
        }
    }

    /// Called when the voice sheet closes: lets go of every loaded model so
    /// the memory goes back to the LLM. Downloaded files on disk stay put.
    func unload() async {
        await asr?.cleanup()
        asr = nil
        await pocket?.cleanup()
        pocket = nil
        pocketLanguagePack = nil
        await supertonic?.cleanup()
        supertonic = nil
        supertonicVoice = nil
    }
}

enum NeuralVoiceError: LocalizedError {
    case unsupportedLanguage
    case unknownVoice
    case notReady

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: "Este idioma no está disponible en la voz de Faro."
        case .unknownVoice: "Esa voz no existe."
        case .notReady: "La voz de Faro aún no está lista."
        }
    }
}
