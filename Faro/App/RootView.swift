import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @State private var selectedID: UUID?

    var body: some View {
        NavigationSplitView {
            ConversationListView(
                conversations: conversations,
                selection: $selectedID,
                onNew: createConversation,
                onDelete: delete
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
                Button(action: createConversation) {
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

    private func createConversation() {
        let conversation = Conversation(
            modelID: DefaultModel.repoID,
            systemPrompt: AppSettings.defaultSystemPrompt
        )
        modelContext.insert(conversation)
        selectedID = conversation.id
    }

    private func delete(_ conversation: Conversation) {
        if selectedID == conversation.id { selectedID = nil }
        modelContext.delete(conversation)
    }
}

#Preview {
    RootView()
        .modelContainer(for: [Conversation.self, ChatMessage.self, MCPServerConfig.self], inMemory: true)
}
