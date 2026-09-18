import SwiftUI

struct GenerationSettingsSheet: View {
    @Bindable var conversation: Conversation
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $conversation.systemPrompt)
                        .frame(minHeight: 100)
                        .font(.body)
                    Button("Usar como predeterminado para conversaciones nuevas") {
                        AppSettings.defaultSystemPrompt = conversation.systemPrompt
                    }
                    .font(.footnote)
                } header: {
                    Text("Prompt del sistema")
                } footer: {
                    Text("Se aplica desde el siguiente mensaje de esta conversación.")
                }

                Section {
                    Toggle("Personalizar generación", isOn: $conversation.useCustomGeneration)
                } footer: {
                    Text("Los valores recomendados funcionan bien para la mayoría de modelos.")
                }

                if conversation.useCustomGeneration {
                    Section("Avanzado") {
                        LabeledSlider(title: "Temperatura", value: $conversation.customTemperature, range: 0...2)
                        LabeledSlider(title: "Top-P", value: $conversation.customTopP, range: 0...1)
                        Stepper("Top-K: \(conversation.customTopK)", value: $conversation.customTopK, in: 0...200)
                        LabeledSlider(title: "Min-P", value: $conversation.customMinP, range: 0...1)
                        LabeledSlider(
                            title: "Penalización de repetición",
                            value: $conversation.customRepetitionPenalty, range: 0...2
                        )
                        Stepper(
                            "Máx. tokens: \(conversation.customMaxTokens)",
                            value: $conversation.customMaxTokens, in: 64...8192, step: 64
                        )
                        Button("Restaurar recomendados", role: .destructive) {
                            conversation.resetGenerationSettings()
                        }
                    }
                }
            }
            .navigationTitle("Personalización")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") {
                        onDismiss()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(FaroColor.ash)
            }
            Slider(value: $value, in: range)
                .tint(FaroColor.lamp)
        }
    }
}
