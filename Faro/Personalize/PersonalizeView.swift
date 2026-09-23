import SwiftUI

struct PersonalizeView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name = Personalization.name
    @State private var context = Personalization.context
    @State private var preferences = Personalization.preferences
    @State private var style = Personalization.style

    var body: some View {
        NavigationStack {
            Form {
                Section("Cómo te llamas") {
                    TextField("Nombre", text: $name)
                        .foregroundStyle(FaroColor.bone)
                }
                Section {
                    TextField("A qué te dedicas", text: $context, axis: .vertical)
                        .lineLimit(2...5)
                        .foregroundStyle(FaroColor.bone)
                } header: {
                    Text("Contexto")
                }
                Section {
                    TextField("Qué debe tener en cuenta Faro al responder", text: $preferences, axis: .vertical)
                        .lineLimit(2...5)
                        .foregroundStyle(FaroColor.bone)
                } header: {
                    Text("Preferencias")
                }
                Section {
                    Picker("Estilo de respuesta", selection: $style) {
                        ForEach(ResponseStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                } footer: {
                    Text("Cada conversación puede cambiarlo por su cuenta.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(FaroColor.ink)
            .tint(FaroColor.lamp)
            .navigationTitle("Personalización")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            // Written back on the way out rather than on every keystroke,
            // same pattern as SettingsView's default system prompt. The
            // profile is part of every conversation's system prompt, which
            // a live session bakes in — drop them all, as for skills.
            .onDisappear {
                Personalization.name = name
                Personalization.context = context
                Personalization.preferences = preferences
                Personalization.style = style
                Task { await InferenceEngine.shared.invalidateAllSessions() }
            }
        }
    }
}
