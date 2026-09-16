import SwiftUI

struct VoiceView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var voice = VoiceSession()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            FaroColor.ink.ignoresSafeArea()

            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    Button {
                        voice.cancel()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(FaroColor.ash)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                BeamView(intensity: beamIntensity)
                    .frame(width: 260, height: 260)
                    .scaleEffect(1 + voice.amplitude * 0.15)

                Text(displayText)
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .frame(minHeight: 60)

                if let error = voice.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(FaroColor.error)
                        .padding(.horizontal, 32)
                }

                Spacer()

                Button(action: primaryAction) {
                    Image(systemName: voice.state == .listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(FaroColor.ink)
                        .frame(width: 76, height: 76)
                        .background(FaroColor.beamCore, in: .circle)
                }
                .disabled(voice.state == .thinking || voice.state == .speaking)
                .opacity(voice.state == .thinking || voice.state == .speaking ? 0.4 : 1)
                .padding(.bottom, 40)
            }
        }
        .task {
            let granted = await voice.requestAuthorization()
            if !granted {
                voice.errorMessage = "Necesito permiso de micrófono y de voz para el modo de conversación."
            }
        }
        .onChange(of: viewModel.isGenerating) { _, isGenerating in
            guard !isGenerating, voice.state == .thinking else { return }
            voice.speak(viewModel.messages.last?.content ?? "")
        }
    }

    private var beamIntensity: Double {
        switch voice.state {
        case .idle: 0.2
        case .listening: 0.4 + voice.amplitude * 0.6
        case .thinking: 1
        case .speaking: 0.5
        }
    }

    private var displayText: String {
        switch voice.state {
        case .idle: "Toca para hablar"
        case .listening: voice.transcript.isEmpty ? "Escuchando…" : voice.transcript
        case .thinking: "Pensando…"
        case .speaking: viewModel.messages.last?.content ?? ""
        }
    }

    private func primaryAction() {
        switch voice.state {
        case .idle:
            voice.startListening()
        case .listening:
            let text = voice.stopListening()
            guard !text.isEmpty else {
                voice.cancel()
                return
            }
            viewModel.draft = text
            viewModel.send()
        case .thinking, .speaking:
            break
        }
    }
}
