import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @Query private var mcpServers: [MCPServerConfig]
    @Query(sort: \Project.createdAt, order: .reverse) private var projects: [Project]
    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            ConversationListView(
                conversations: conversations,
                projects: projects,
                selection: $selectedID,
                onNew: createConversation,
                onDelete: delete,
                onDeleteProject: deleteProject
            )
        } detail: {
            if let conversation = conversations.first(where: { $0.id == selectedID }) {
                ChatView(viewModel: ChatViewModel(conversation: conversation, modelContext: modelContext))
                    .id(conversation.id)
            } else {
                emptyDetail
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if selectedID == nil { selectedID = conversations.first?.id }
        }
        // `MCPServerConfig.isEnabled` survives an app relaunch (SwiftData),
        // but `MCPConnectionManager`'s live clients don't — they're actor
        // state that resets to empty every launch. Without this, a server
        // still shows "on" in Settings while the model silently gets no
        // tools at all until the user happens to revisit that screen.
        .task { await reconnectEnabledMCPServers() }
    }

    private func reconnectEnabledMCPServers() async {
        for server in mcpServers where server.isEnabled {
            do {
                _ = try await MCPConnectionManager.shared.connect(server.snapshot)
            } catch {
                server.isEnabled = false
            }
        }
        try? modelContext.save()
    }

    private var emptyDetail: some View {
        ZStack {
            FaroColor.ink.ignoresSafeArea()
            VStack(spacing: 8) {
                BeamView(intensity: 0.2)
                    .frame(width: 220, height: 220)
                Text("Faro")
                    .font(.system(size: 34, weight: .regular, design: .serif))
                    .foregroundStyle(FaroColor.bone)
                Button { createConversation(in: nil) } label: {
                    Text("Nueva conversación")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(FaroColor.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(FaroColor.bone, in: .rect(cornerRadius: 14))
                }
                .padding(.top, 20)
            }
        }
    }

    /// A conversation started inside a project uses the project's
    /// instructions instead of the app-wide default — the project's
    /// context block already carries them via `effectiveSystemPrompt`.
    private func createConversation(in project: Project?) {
        let conversation = Conversation(
            modelID: DefaultModel.resolve(
                remembered: AppSettings.lastModelID,
                downloaded: ModelCacheStore.downloadedIDs()
            ),
            systemPrompt: project == nil ? AppSettings.defaultSystemPrompt : ""
        )
        conversation.project = project
        modelContext.insert(conversation)
        selectedID = conversation.id
    }

    private func delete(_ conversation: Conversation) {
        if selectedID == conversation.id { selectedID = nil }
        modelContext.delete(conversation)
    }

    /// `.nullify` on `Conversation.project` means its conversations survive
    /// as loose chats — deleting a project shouldn't take history with it.
    private func deleteProject(_ project: Project) {
        modelContext.delete(project)
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Conversation.self, ChatMessage.self, Project.self, MCPServerConfig.self], inMemory: true)
}
