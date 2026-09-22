import SwiftUI
import SwiftData

struct ConversationListView: View {
    let conversations: [Conversation]
    let projects: [Project]
    @Binding var selection: UUID?
    /// `nil` starts a loose conversation; a project starts one inside it.
    let onNew: (Project?) -> Void
    let onDelete: (Conversation) -> Void
    let onDeleteProject: (Project) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var showSettings = false
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""
    @State private var editingProject: Project?

    var body: some View {
        List(selection: $selection) {
            // Projects only show up once one exists, so the plain,
            // pre-projects list stays exactly as it was for anyone who
            // never uses them.
            if projects.isEmpty {
                looseConversationRows
            } else {
                Section("Proyectos") {
                    ForEach(projects) { project in
                        projectRow(project)
                    }
                }
                Section("Conversaciones") {
                    looseConversationRows
                }
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
                Button {
                    showNewProjectAlert = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("Nuevo proyecto")
            }
            ToolbarItem {
                Button { onNew(nil) } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Nueva conversación")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $editingProject) { project in
            ProjectSheet(project: project)
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
        .alert("Nuevo proyecto", isPresented: $showNewProjectAlert) {
            TextField("Nombre", text: $newProjectName)
            Button("Crear") { commitNewProject() }
            Button("Cancelar", role: .cancel) { newProjectName = "" }
        }
    }

    @ViewBuilder
    private var looseConversationRows: some View {
        let loose = conversations.filter { $0.project == nil }
        if loose.isEmpty && projects.isEmpty {
            Text("Todavía no hay conversaciones.")
                .font(.footnote)
                .foregroundStyle(FaroColor.ash)
                .listRowBackground(Color.clear)
        }
        ForEach(loose) { conversation in
            conversationRow(conversation)
        }
        .onDelete { offsets in
            for index in offsets { onDelete(loose[index]) }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let members = conversations.filter { $0.project?.id == project.id }
        return DisclosureGroup {
            ForEach(members) { conversation in
                conversationRow(conversation)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .foregroundStyle(FaroColor.bone)
                    .lineLimit(1)
                Text(members.count == 1 ? "1 conversación" : "\(members.count) conversaciones")
                    .font(.caption)
                    .foregroundStyle(FaroColor.ash)
            }
            .contextMenu {
                Button { editingProject = project } label: {
                    Label("Editar", systemImage: "pencil")
                }
                Button { onNew(project) } label: {
                    Label("Nueva conversación", systemImage: "plus")
                }
                Button(role: .destructive) { onDeleteProject(project) } label: {
                    Label("Eliminar", systemImage: "trash")
                }
            }
        }
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
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
            if !projects.isEmpty {
                Menu {
                    if conversation.project != nil {
                        Button("Ninguno") { move(conversation, to: nil) }
                    }
                    ForEach(projects) { project in
                        Button(project.name) { move(conversation, to: project) }
                    }
                } label: {
                    Label("Mover a proyecto", systemImage: "folder")
                }
            }
            Button(role: .destructive) {
                onDelete(conversation)
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
    }

    private func commitRename() {
        defer { renaming = nil }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let conversation = renaming, !trimmed.isEmpty else { return }
        conversation.title = trimmed
        try? modelContext.save()
    }

    private func commitNewProject() {
        defer { newProjectName = "" }
        let trimmed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let project = Project(name: trimmed)
        modelContext.insert(project)
        // Straight into its settings — a name alone isn't a useful project
        // yet, and "Editar" from the context menu is the only other way in.
        editingProject = project
    }

    private func move(_ conversation: Conversation, to project: Project?) {
        conversation.project = project
        try? modelContext.save()
    }
}
