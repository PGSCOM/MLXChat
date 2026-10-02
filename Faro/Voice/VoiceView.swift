import SwiftUI

struct VoiceView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var voice = VoiceSession()
    @State private var showVoiceSettings = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            FaroColor.ink.ignoresSafeArea()

            VStack(spacing: 24) {
                HStack {
                    // The language being wrong is something you notice
                    // here, not three screens away in settings.
                    Button {
                        showVoiceSettings = true
                    } label: {
                        Image(systemName: "globe")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(FaroColor.ash)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Idioma y voz")
                    Spacer()
                    Button {
                        voice.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(FaroColor.ash)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Salir del modo voz")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                Spacer()

                BeamView(intensity: beamIntensity)
                    .frame(width: 260, height: 260)
                    .scaleEffect(1 + voice.amplitude * 0.15)

                Text(displayText)
                    .font(.system(size: 17))
                    .foregroundStyle(voice.state == .listening && voice.transcript.isEmpty ? FaroColor.ash : FaroColor.bone)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .frame(minHeight: 72, alignment: .top)

                if let error = voice.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(FaroColor.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                Button(action: primaryAction) {
                    Image(systemName: voice.state == .listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(FaroColor.ink)
                        .frame(width: 76, height: 76)
                        .background(FaroColor.bone, in: .circle)
                }
                .disabled(!canTalk)
                .opacity(canTalk ? 1 : 0.35)
                .accessibilityLabel(voice.state == .listening ? "Terminar de hablar" : "Hablar")
                .padding(.bottom, 40)
            }
        }
        .task {
            let granted = await voice.requestAuthorization()
            guard granted else {
                voice.errorMessage = "Necesito permiso de micrófono para el modo de conversación."
                return
            }
            await voice.prepare()
        }
        .onChange(of: viewModel.isGenerating) { _, isGenerating in
            guard !isGenerating, voice.state == .thinking else { return }
            voice.speak(lastAnswer)
        }
        .onDisappear {
            voice.cancel()
            Task { await NeuralVoice.shared.unload() }
        }
        .sheet(isPresented: $showVoiceSettings) {
            VoiceSettingsView()
        }
    }

    private var canTalk: Bool { voice.state == .idle || voice.state == .listening }

    /// The assistant's own last turn — never `messages.last`, which is the
    /// user's question whenever a turn produced nothing.
    private var lastAnswer: String {
        viewModel.messages.last { $0.role == .assistant }?.content ?? ""
    }

    private var beamIntensity: Double {
        switch voice.state {
        case .idle: 0.2
        case .preparing: 0.3
        case .listening: 0.4 + voice.amplitude * 0.6
        case .thinking: 1
        case .speaking: 0.5
        }
    }

    private var displayText: String {
        switch voice.state {
        case .idle: "Toca para hablar"
        case .preparing: preparingText
        case .listening: voice.transcript.isEmpty ? "Escuchando…" : voice.transcript
        // The answer streams in while it's still being written, so the
        // wait shows progress instead of a blank screen.
        case .thinking: lastAnswer.isEmpty ? "Pensando…" : lastAnswer
        case .speaking: lastAnswer
        }
    }

    private var preparingText: String {
        guard let progress = voice.prepareProgress, progress > 0 else { return "Preparando la voz…" }
        return "Descargando voz… \(Int(progress * 100)) %"
    }

    private func primaryAction() {
        switch voice.state {
        case .idle:
            Task { await voice.startListening() }
        case .listening:
            Task {
                let text = await voice.stopListening()
                guard !text.isEmpty else {
                    voice.cancel()
                    return
                }
                viewModel.draft = text
                viewModel.send()
                // `send()` refuses while a turn is already running; without
                // this the session would sit in `.thinking` forever waiting
                // for a generation that never started.
                if !viewModel.isGenerating { voice.cancel() }
            }
        case .preparing, .thinking, .speaking:
            break
        }
    }
}
