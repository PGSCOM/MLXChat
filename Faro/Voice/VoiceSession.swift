import Foundation
import Observation
import Speech
import AVFoundation

/// Speech-to-text and text-to-speech for the voice mode.
///
/// Two engines share this one class: `.apple` (`SFSpeechRecognizer` +
/// `AVSpeechSynthesizer`, unchanged from before) and `.neural` (Faro's own
/// on-device models, see `NeuralVoice`). Which one a turn actually uses is
/// decided once, in `prepare()`, and cached in `effectiveEngine` — never
/// re-decided mid-turn, so a listen/speak pair never splits across engines.
///
/// ponytail: `.apple` still uses `SFSpeechRecognizer` (stable since iOS 10,
/// on-device via `requiresOnDeviceRecognition`), not the new iOS 26
/// `SpeechAnalyzer` / `SpeechTranscriber`. That API is so new that neither
/// Apple's own docs page nor the handful of sample repos around it yield a
/// verifiable signature right now — shipping against a guessed API is worse
/// than shipping the boring, correct one. Revisit once it's documented.
@Observable
@MainActor
final class VoiceSession: NSObject {
    enum State: Equatable {
        case idle
        /// Downloading/loading the neural models. Only ever entered once
        /// per app run per language+backend — `NeuralVoice.prepare` is a
        /// no-op once everything's already resident.
        case preparing
        case listening
        case thinking
        case speaking
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    /// 0...1, driven by real mic input level — not decorative.
    private(set) var amplitude: Double = 0
    /// 0...1 while `.preparing`; nil once nothing's downloading.
    private(set) var prepareProgress: Double?
    var errorMessage: String?

    /// Decided once per `prepare()` call, from `VoiceSettings.engine` plus
    /// whether the neural models actually cover the current language — a
    /// language neither Parakeet nor the chosen TTS backend supports falls
    /// back to Apple rather than failing the whole voice mode.
    private var effectiveEngine: VoiceEngine = .apple

    /// Rebuilt on every tap of the mic from `VoiceSettings`, so changing
    /// the language mid-session just works — no staleness window, no
    /// observation of the settings store.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    /// Filled in only while `effectiveEngine == .neural` and listening.
    private var sampleBuffer: AudioSampleBuffer?
    private var recordingSampleRate: Double = 16_000

    /// Separate engine for neural playback — `audioEngine` above is input-
    /// only (a tap on `inputNode`); mixing playback onto it would mean
    /// tearing down and rebuilding the tap's format every turn.
    private let playerEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var speakTask: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
        playerEngine.attach(playerNode)
    }

    /// Only the microphone — Speech Recognition's own permission is
    /// requested lazily, right before the Apple engine is actually used,
    /// so the neural default (which never touches `SFSpeechRecognizer`)
    /// doesn't prompt for a permission it doesn't need.
    func requestAuthorization() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func requestSpeechAuthorizationIfNeeded() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Downloads (first run only) and loads whatever this turn's engine
    /// needs. Call before the mic button becomes usable.
    func prepare() async {
        let languageCode = VoiceSettings.neuralLanguageCode
        let tts = VoiceSettings.neuralTTS
        let wantsNeural = VoiceSettings.engine == .neural
            && NeuralVoice.supportsListening(languageCode: languageCode)
            && NeuralVoice.supportsSpeaking(languageCode: languageCode, tts: tts)
        effectiveEngine = wantsNeural ? .neural : .apple

        guard wantsNeural else { return }
        state = .preparing
        prepareProgress = 0
        do {
            try await NeuralVoice.shared.prepare(
                languageCode: languageCode, tts: tts, voiceID: VoiceSettings.neuralVoiceID
            ) { [weak self] progress in
                Task { @MainActor in self?.prepareProgress = progress }
            }
        } catch {
            errorMessage = error.localizedDescription
            effectiveEngine = .apple
        }
        prepareProgress = nil
        state = .idle
    }

    func startListening() async {
        guard state == .idle else { return }
        transcript = ""
        errorMessage = nil

        if effectiveEngine == .apple {
            guard await requestSpeechAuthorizationIfNeeded() else {
                errorMessage = "Necesito permiso de Reconocimiento de voz para este idioma."
                return
            }
        }

        // Before anything touches `inputNode`: activating the session
        // changes the hardware format, and installing a tap with the old
        // one is the classic AVAudioEngine crash.
        do {
            try activateAudioSession()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        var recognizer: SFSpeechRecognizer?
        if effectiveEngine == .apple {
            guard let found = SFSpeechRecognizer(locale: VoiceSettings.recognitionLocale), found.isAvailable else {
                errorMessage = "El reconocimiento de voz no está disponible en este idioma."
                return
            }
            recognizer = found
            self.recognizer = found
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if let recognizer {
            // Forcing on-device for a language whose assets aren't installed
            // just makes the request fail, so ask for it only where it exists.
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }
        if effectiveEngine == .apple {
            self.request = request
        }

        // ponytail: the neural path records into one buffer and transcribes
        // it once at `stopListening()`, rather than re-running Parakeet on
        // the growing buffer every second for a live partial transcript —
        // that's an O(n²) cost across a long turn for a "nice to have".
        // Add incremental partials (FluidAudio's streaming ASR) if push-to-
        // talk turns end up running long enough to want them.
        let buffer = effectiveEngine == .neural ? AudioSampleBuffer() : nil
        sampleBuffer = buffer

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        recordingSampleRate = format.sampleRate
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] pcmBuffer, _ in
            if let buffer {
                buffer.append(Self.floatSamples(of: pcmBuffer))
            } else {
                request.append(pcmBuffer)
            }
            let level = Self.rmsLevel(of: pcmBuffer)
            Task { @MainActor in self?.amplitude = level }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = error.localizedDescription
            self.request = nil
            sampleBuffer = nil
            return
        }

        state = .listening

        guard let recognizer else { return }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                // `stopListening()` cancels the task, which then reports a
                // cancellation error after we've already moved on — only a
                // failure while still listening is a real failure. Without
                // the state guard every normal turn would show an error;
                // without handling it at all the UI sat on "Escuchando…"
                // for ever, because `teardownAudio()` doesn't touch state.
                if let error, self.state == .listening {
                    self.errorMessage = error.localizedDescription
                    self.teardownAudio()
                    self.deactivateAudioSession()
                    self.state = .idle
                    return
                }
                if result?.isFinal == true {
                    self.teardownAudio()
                }
            }
        }
    }

    /// Stops capturing and returns whatever was transcribed. On the neural
    /// engine this is where the recording actually gets transcribed — there
    /// is no live partial (see the note in `startListening`).
    @discardableResult
    func stopListening() async -> String {
        let buffer = sampleBuffer
        let sampleRate = recordingSampleRate
        teardownAudio()
        state = .thinking

        sampleBuffer = nil
        guard let buffer else { return transcript }
        let samples = buffer.drain()
        guard !samples.isEmpty else { return "" }
        do {
            transcript = try await NeuralVoice.shared.transcribe(
                samples: samples, sampleRate: sampleRate, languageCode: VoiceSettings.neuralLanguageCode
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        return transcript
    }

    func speak(_ text: String) {
        guard !text.isEmpty else {
            deactivateAudioSession()
            state = .idle
            return
        }
        do {
            try activateAudioSession()
        } catch {
            errorMessage = error.localizedDescription
            state = .idle
            return
        }
        state = .speaking

        if effectiveEngine == .apple {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = VoiceSettings.voice()
            synthesizer.speak(utterance)
            return
        }

        // Markdown syntax read aloud verbatim ("asterisco asterisco...")
        // is worse than losing the formatting.
        let plainText = (try? AttributedString(markdown: text))
            .map { String($0.characters) } ?? text
        let tts = VoiceSettings.neuralTTS
        let languageCode = VoiceSettings.neuralLanguageCode
        let voiceID = VoiceSettings.neuralVoiceID
        speakTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (samples, sampleRate) = try await NeuralVoice.shared.speak(
                    plainText, tts: tts, languageCode: languageCode, voiceID: voiceID
                )
                guard !Task.isCancelled else { return }
                await self.play(samples: samples, sampleRate: sampleRate)
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.finishSpeaking()
            }
        }
    }

    private func play(samples: [Float], sampleRate: Double) async {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            finishSpeaking()
            return
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }

        do {
            // Reconnected every call: PocketTTS (24kHz) and Supertonic-3
            // (44.1kHz) don't share a sample rate, and the engine has to be
            // stopped to change a connection's format.
            if playerEngine.isRunning { playerEngine.stop() }
            playerEngine.disconnectNodeOutput(playerNode)
            playerEngine.connect(playerNode, to: playerEngine.mainMixerNode, format: format)
            playerEngine.prepare()
            try playerEngine.start()
        } catch {
            errorMessage = error.localizedDescription
            finishSpeaking()
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                continuation.resume()
            }
            playerNode.play()
        }
        finishSpeaking()
    }

    func cancel() {
        teardownAudio()
        speakTask?.cancel()
        speakTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        // Stopping the node still fires its buffer's completion handler,
        // which is what unblocks `play(samples:sampleRate:)`'s continuation.
        playerNode.stop()
        if playerEngine.isRunning { playerEngine.stop() }
        deactivateAudioSession()
        state = .idle
        amplitude = 0
    }

    /// The utterance ended on its own (or was stopped): let go of the
    /// audio route so other audio can come back.
    fileprivate func finishSpeaking() {
        guard state == .speaking else { return }
        deactivateAudioSession()
        state = .idle
    }

    /// Recording and speaking share one session: `.playAndRecord` stays
    /// active across the listen → answer → speak cycle so the route
    /// doesn't flip (and the speaker doesn't drop to the earpiece)
    /// between the two halves of a turn.
    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func teardownAudio() {
        amplitude = 0
        // The engine guard only covers the engine: with it wrapping the
        // whole body, a teardown after the engine had already stopped left
        // the request and the task alive.
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    nonisolated private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frameLength {
            sum += data[index] * data[index]
        }
        let rms = sqrt(sum / Float(frameLength))
        return Double(min(rms * 20, 1))
    }

    nonisolated private static func floatSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}

extension VoiceSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }
}

/// Accumulates mic samples off the main actor — the tap closure runs on an
/// audio thread, so this can't be a plain `@MainActor` array. Mirrors how
/// `request.append(buffer)` above is called from that same closure on a
/// captured local, not a `self`-isolated property.
private final class AudioSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ new: [Float]) {
        lock.lock()
        samples.append(contentsOf: new)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }
}
