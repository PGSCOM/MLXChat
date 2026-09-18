import SwiftUI
import SwiftData

struct ConversationListView: View {
    let conversations: [Conversation]
    @Binding var selection: UUID?
    let onNew: () -> Void
    let onDelete: (Conversation) -> Void

    @State private var showServerPanel = false
    @State private var showMCPServers = false

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
                    showMCPServers = true
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                }
                .accessibilityLabel("Herramientas MCP")
            }
            ToolbarItem {
                Button {
                    showServerPanel = true
                } label: {
                    Image(systemName: "network")
                }
                .accessibilityLabel("Servidor local")
            }
            ToolbarItem {
                Button(action: onNew) {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Nueva conversación")
            }
        }
        .sheet(isPresented: $showServerPanel) {
            ServerPanelView()
        }
        .sheet(isPresented: $showMCPServers) {
            MCPServersView()
        }
    }
}
