import SwiftUI
import SwiftData

struct ConversationListView: View {
    let conversations: [Conversation]
    @Binding var selection: UUID?
    let onNew: () -> Void
    let onDelete: (Conversation) -> Void

    @State private var showServerPanel = false

    var body: some View {
        List(selection: $selection) {
            ForEach(conversations) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(conversation.createdAt, style: .date)
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
        .scrollContentBackground(.hidden)
        .background(FaroColor.ink)
        .navigationTitle("Faro")
        .toolbar {
            ToolbarItem {
                Button {
                    showServerPanel = true
                } label: {
                    Image(systemName: "network")
                }
            }
            ToolbarItem {
                Button(action: onNew) {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showServerPanel) {
            ServerPanelView()
        }
    }
}
