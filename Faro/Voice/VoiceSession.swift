import Foundation
import Observation
import Speech
import AVFoundation

/// Speech-to-text and text-to-speech for the voice mode.
///
/// ponytail: uses `SFSpeechRecognizer` (stable since iOS 10, on-device via
/// `requiresOnDeviceRecognition`), not the new iOS 26 `SpeechAnalyzer` /
/// `SpeechTranscriber`. That API is so new that neither Apple's own docs
/// page nor the handful of sample repos around it yield a verifiable
/// signature right now — shipping against a guessed API is worse than
/// shipping the boring, correct one. Revisit once it's documented.
@Observable
@MainActor
final class VoiceSession: NSObject {
    enum State: Equatable {
        case idle
        case listening
        case thinking
        case speaking
    }

    private(set) var state: State = .idle
    private(set) var transcript = ""
    /// 0...1, driven by real mic input level — not decorative.
    private(set) var amplitude: Double = 0
    var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: .current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func startListening() {
        guard state == .idle else { return }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "El reconocimiento de voz no está disponible en este idioma."
            return
        }
        transcript = ""
        errorMessage = nil

        // Before anything touches `inputNode`: activating the session
        // changes the hardware format, and installing a tap with the old
        // one is the classic AVAudioEngine crash.
        do {
            try activateAudioSession()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.rmsLevel(of: buffer)
            Task { @MainActor in self?.amplitude = level }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            errorMessage = error.localizedDescription
            self.request = nil
            return
        }

        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.teardownAudio()
                }
            }
        }
    }

    /// Stops capturing and returns whatever was transcribed so far.
    @discardableResult
    func stopListening() -> String {
        teardownAudio()
        state = .thinking
        return transcript
    }

    func speak(_ text: String) {
        guard !text.isEmpty else {
            deactivateAudioSession()
            state = .idle
            return
        }
        try? activateAudioSession()
        state = .speaking
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
        synthesizer.speak(utterance)
    }

    func cancel() {
        teardownAudio()
        synthesizer.stopSpeaking(at: .immediate)
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
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
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
}

extension VoiceSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }
}
