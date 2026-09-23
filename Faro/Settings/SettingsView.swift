import SwiftUI
import SwiftData

/// Everything that configures the app, in one place. These used to be
/// three separate toolbar buttons across two different bars; the point of
/// this screen is that there is now one.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var conversations: [Conversation]

    @State private var destination: Destination?
    @State private var systemPrompt = AppSettings.defaultSystemPrompt
    @State private var pendingHistoryDeletion = false
    @State private var pendingReset = false

    private enum Destination: String, Identifiable {
        case models, voice, server, mcp, personalize, skills
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("App") {
                    row("Administrar modelos", icon: "shippingbox", to: .models)
                    row("Voz", icon: "waveform", to: .voice)
                    row("Servidor local", icon: "network", to: .server)
                    row("Herramientas MCP", icon: "wrench.and.screwdriver", to: .mcp)
                    row("Personalización", icon: "person.crop.circle", to: .personalize)
                    row("Skills", icon: "sparkles", to: .skills)
                }

                Section {
                    TextField("Cómo debe responder el modelo", text: $systemPrompt, axis: .vertical)
                        .lineLimit(3...8)
                        .foregroundStyle(FaroColor.bone)
                } header: {
                    Text("Instrucciones predeterminadas")
                } footer: {
                    Text("Se aplican a las conversaciones nuevas. Cada conversación puede cambiarlas por su cuenta.")
                }

                Section {
                    Button("Eliminar historial de conversaciones", role: .destructive) {
                        pendingHistoryDeletion = true
                    }
                    .disabled(conversations.isEmpty)
                    Button("Restablecer Faro", role: .destructive) {
                        pendingReset = true
                    }
                } footer: {
                    Text("Todo ocurre en este dispositivo: nada de esto sale de aquí.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(FaroColor.ink)
            .tint(FaroColor.lamp)
            .navigationTitle("Configuración")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            // Written back on the way out rather than on every keystroke.
            .onDisappear { AppSettings.defaultSystemPrompt = systemPrompt }
            .sheet(item: $destination) { sheet(for: $0) }
            .confirmationDialog(
                "¿Eliminar todas las conversaciones?",
                isPresented: $pendingHistoryDeletion,
                titleVisibility: .visible
            ) {
                Button("Eliminar todo", role: .destructive) { deleteHistory() }
                Button("Cancelar", role: .cancel) { pendingHistoryDeletion = false }
            } message: {
                Text("Se borrarán \(conversations.count) conversaciones. No se puede deshacer.")
            }
            .confirmationDialog("¿Restablecer Faro?", isPresented: $pendingReset, titleVisibility: .visible) {
                Button("Restablecer y borrar modelos", role: .destructive) { reset(deletingModels: true) }
                Button("Restablecer y conservar modelos", role: .destructive) { reset(deletingModels: false) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Se borrarán conversaciones, proyectos, servidores MCP y ajustes, como si la app se acabara de instalar. No se puede deshacer.")
            }
        }
    }

    private func row(_ title: String, icon: String, to target: Destination) -> some View {
        Button {
            destination = target
        } label: {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(FaroColor.bone)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FaroColor.ash)
            }
        }
    }

    /// Presented as sheets, not pushed: each of these views brings its own
    /// `NavigationStack` and close button, so pushing them would mean
    /// rewriting all four.
    @ViewBuilder private func sheet(for destination: Destination) -> some View {
        switch destination {
        case .models:
            // No conversation to retarget from here — picking one only sets
            // what the next new conversation starts with.
            ModelBrowserView(
                currentModelID: AppSettings.lastModelID,
                onSelect: { AppSettings.lastModelID = $0 }
            )
        case .voice:
            VoiceSettingsView()
        case .server:
            ServerPanelView()
        case .mcp:
            MCPServersView()
        case .personalize:
            PersonalizeView()
        case .skills:
            SkillsView()
        }
    }

    private func deleteHistory() {
        pendingHistoryDeletion = false
        // Read now: `@Query` and `@Environment` aren't meant to be read
        // after an `await`, once the view may have moved on.
        let doomed = conversations
        let context = modelContext
        Task {
            await ChatViewModel.prepareForDeletion(Set(doomed.map(\.id)))
            for conversation in doomed {
                context.delete(conversation)
            }
            try? context.save()
        }
    }

    private func reset(deletingModels: Bool) {
        // Cleared here too, or `onDisappear` would write the old one back.
        systemPrompt = ""
        let context = modelContext
        let close = dismiss
        Task {
            await AppReset.run(in: context, deletingModels: deletingModels)
            close()
        }
    }
}
