import SwiftUI
import SwiftData

struct ConversationListView: View {
    let conversations: [Conversation]
    @Binding var selection: UUID?
    let onNew: () -> Void
    let onDelete: (Conversation) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var showSettings = false
    @State private var renaming: Conversation?
    @State private var newTitle = ""

    var body: some View {
        List(selection: $selection) {
            if conversations.isEmpty {
                Text("Todavía no hay conversaciones.")
                    .font(.footnote)
                    .foregroundStyle(FaroColor.ash)
                    .listRowBackground(Color.clear)
            }
            ForEach(conversations) { conversation in
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .foregroundStyle(FaroColor.bone)
                        .lineLimit(1)
                    Text(conversation.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(FaroColor.ash)
                }
                .tag(conversation.id)
                .contextMenu {
                    Button {
                        newTitle = conversation.title
                        renaming = conversation
                    } label: {
                        Label("Renombrar", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete(conversation)
                    } label: {
                        Label("Eliminar", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { onDelete(conversations[index]) }
            }
        }
        .listStyle(.sidebar)
        .tint(FaroColor.lamp)
        .scrollContentBackground(.hidden)
        .background(FaroColor.ink)
        .navigationTitle("Faro")
        .toolbar {
            ToolbarItem {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Configuración")
            }
            ToolbarItem {
                Button(action: onNew) {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Nueva conversación")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .alert(
            "Renombrar conversación",
            isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )
        ) {
            TextField("Título", text: $newTitle)
            Button("Guardar") { commitRename() }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
    }

    private func commitRename() {
        defer { renaming = nil }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversation = renaming, !trimmed.isEmpty else { return }
        conversation.title = trimmed
        try? modelContext.save()
    }
}
