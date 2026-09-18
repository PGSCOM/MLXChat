import SwiftUI
import Speech
import AVFoundation

/// Language and voice for the conversation mode. Both lists come from the
/// system: what Apple can transcribe on this device, and which of Apple's
/// voices are actually installed.
struct VoiceSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var localeID = VoiceSettings.recognitionLocaleID
    @State private var voiceID = VoiceSettings.synthesisVoiceID
    @State private var locales: [Locale] = []
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var recognizesOnDevice = true
    @State private var synthesizer = AVSpeechSynthesizer()

    var body: some View {
        NavigationStack {
            Form {
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
                    Text(recognizesOnDevice
                         ? "Se transcribe en el dispositivo: tu voz no sale de aquí."
                         : "Este idioma se transcribe en los servidores de Apple, no en el dispositivo.")
                }

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
            .onChange(of: localeID) { _, newValue in
                VoiceSettings.recognitionLocaleID = newValue
                // The chosen voice belongs to the old language.
                voiceID = ""
                VoiceSettings.synthesisVoiceID = ""
                refreshForSelectedLanguage()
            }
            .onChange(of: voiceID) { _, newValue in
                VoiceSettings.synthesisVoiceID = newValue
            }
        }
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
}
