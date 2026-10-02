import SwiftUI
import Speech
import AVFoundation

/// Engine, language and voice for the conversation mode. `.neural` (Faro's
/// own on-device models) is the default; `.apple` keeps the original
/// `SFSpeechRecognizer` + `AVSpeechSynthesizer` path for anyone who prefers
/// it, or for a language the neural models don't cover.
struct VoiceSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var engine = VoiceSettings.engine
    @State private var localeID = VoiceSettings.recognitionLocaleID
    @State private var voiceID = VoiceSettings.synthesisVoiceID
    @State private var neuralTTS = VoiceSettings.neuralTTS
    @State private var neuralVoiceID = VoiceSettings.neuralVoiceID
    @State private var locales: [Locale] = []
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var recognizesOnDevice = true
    @State private var synthesizer = AVSpeechSynthesizer()
    @State private var testSession = VoiceSession()
    @State private var isTestingNeural = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Motor", selection: $engine) {
                        Text("Faro (en el dispositivo)").tag(VoiceEngine.neural)
                        Text("Apple").tag(VoiceEngine.apple)
                    }
                } footer: {
                    Text(engine == .neural
                         ? "Escucha y responde con modelos propios en el dispositivo (FluidAudio), sin depender del reconocimiento ni de las voces de Apple."
                         : "Usa el reconocimiento de voz y las voces del sistema.")
                }

                Section {
                    Picker("Idioma", selection: $localeID) {
                        Text("Automático (\(systemLanguageName))").tag("")
                        ForEach(locales, id: \.identifier) { locale in
                            Text(name(of: locale)).tag(locale.identifier)
                        }
                    }
                } header: {
                    Text("Reconocimiento")
                } footer: {
                    if engine == .neural {
                        Text("Se transcribe en el dispositivo con Parakeet. Si el idioma elegido no está soportado, esta conversación usará Apple automáticamente.")
                    } else {
                        Text(recognizesOnDevice
                             ? "Se transcribe en el dispositivo: tu voz no sale de aquí."
                             : "Este idioma se transcribe en los servidores de Apple, no en el dispositivo.")
                    }
                }

                if engine == .neural {
                    Section {
                        Picker("Modelo", selection: $neuralTTS) {
                            Text("PocketTTS").tag(NeuralTTSBackend.pocket)
                            Text("Supertonic-3").tag(NeuralTTSBackend.supertonic)
                        }
                        Picker("Voz", selection: $neuralVoiceID) {
                            Text("Automática").tag("")
                            ForEach(neuralVoiceOptions, id: \.self) { name in
                                Text(name.capitalized).tag(name)
                            }
                        }
                        Button {
                            testNeural()
                        } label: {
                            HStack {
                                Text("Probar voz")
                                if isTestingNeural {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isTestingNeural)
                    } header: {
                        Text("Respuesta hablada")
                    } footer: {
                        Text(neuralTTS == .pocket
                             ? "PocketTTS (Kyutai): voz nativa por idioma, streaming. Se descarga una vez (~550 MB)."
                             : "Supertonic-3: cobertura de 31 idiomas. Se descarga una vez (~400 MB).")
                    }
                } else {
                    Section {
                        Picker("Voz", selection: $voiceID) {
                            Text("Automática").tag("")
                            ForEach(voices, id: \.identifier) { voice in
                                Text(voice.name + VoiceSettings.qualityLabel(voice.quality))
                                    .tag(voice.identifier)
                            }
                        }
                        if voices.isEmpty {
                            Text("No hay ninguna voz instalada para este idioma.")
                                .font(.footnote)
                                .foregroundStyle(FaroColor.ash)
                        }
                        Button("Probar voz") { test() }
                            .disabled(voices.isEmpty)
                    } header: {
                        Text("Respuesta hablada")
                    } footer: {
                        Text("Las voces Premium y Mejoradas de Apple suenan mucho mejor, pero hay que descargarlas en Ajustes › Accesibilidad › Contenido hablado › Voces. Aquí solo aparecen las que ya están instaladas.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FaroColor.ink)
            .tint(FaroColor.lamp)
            .navigationTitle("Voz")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .task { await loadLocales() }
            .onChange(of: engine) { _, newValue in
                VoiceSettings.engine = newValue
            }
            .onChange(of: localeID) { _, newValue in
                VoiceSettings.recognitionLocaleID = newValue
                // The chosen voice belongs to the old language.
                voiceID = ""
                VoiceSettings.synthesisVoiceID = ""
                neuralVoiceID = ""
                VoiceSettings.neuralVoiceID = ""
                refreshForSelectedLanguage()
            }
            .onChange(of: voiceID) { _, newValue in
                VoiceSettings.synthesisVoiceID = newValue
            }
            .onChange(of: neuralTTS) { _, newValue in
                VoiceSettings.neuralTTS = newValue
                neuralVoiceID = ""
                VoiceSettings.neuralVoiceID = ""
            }
            .onChange(of: neuralVoiceID) { _, newValue in
                VoiceSettings.neuralVoiceID = newValue
            }
        }
    }

    private var neuralVoiceOptions: [String] {
        neuralTTS == .pocket ? VoiceSettings.pocketVoices : VoiceSettings.supertonicVoices
    }

    private var systemLanguageName: String {
        name(of: .current)
    }

    private func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// `supportedLocales()` is a system call and the list runs to dozens of
    /// entries, so it's built once rather than inside `body`.
    private func loadLocales() async {
        locales = SFSpeechRecognizer.supportedLocales()
            .sorted { name(of: $0).localizedCaseInsensitiveCompare(name(of: $1)) == .orderedAscending }
        refreshForSelectedLanguage()
    }

    /// One recognizer, for the selected language only — never one per row.
    private func refreshForSelectedLanguage() {
        recognizesOnDevice = SFSpeechRecognizer(locale: VoiceSettings.recognitionLocale)?
            .supportsOnDeviceRecognition ?? false
        voices = VoiceSettings.installedVoices(for: VoiceSettings.speechLanguageTag)
    }

    private func test() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: "Hola, así sueno en este idioma.")
        utterance.voice = VoiceSettings.voice()
        synthesizer.speak(utterance)
    }

    /// Loads (downloading on first use) and speaks a sample with the
    /// currently-picked neural backend and voice.
    private func testNeural() {
        isTestingNeural = true
        Task {
            await testSession.prepare()
            testSession.speak("Hola, así sueno en este idioma.")
            isTestingNeural = false
        }
    }
}
