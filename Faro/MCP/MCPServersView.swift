import SwiftUI
import SwiftData

struct MCPServersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MCPServerConfig.createdAt) private var servers: [MCPServerConfig]

    @State private var showAddSheet = false
    @State private var toolsByServer: [UUID: [MCPToolSummary]] = [:]
    @State private var errors: [UUID: String] = [:]
    @State private var pendingConfirmation: MCPServerConfig?

    var body: some View {
        NavigationStack {
            List {
                if servers.isEmpty {
                    Text("Añade un servidor MCP para dar herramientas externas al modelo.")
                        .foregroundStyle(FaroColor.ash)
                }
                ForEach(servers) { server in
                    Section {
                        Toggle(
                            server.name,
                            isOn: Binding(
                                get: { server.isEnabled },
                                set: { toggle(server, to: $0) }
                            )
                        )
                        .tint(FaroColor.lamp)

                        Text(server.url)
                            .font(.footnote)
                            .foregroundStyle(FaroColor.ash)

                        if let tools = toolsByServer[server.id], !tools.isEmpty {
                            ForEach(tools, id: \.name) { tool in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.name).font(.footnote.weight(.medium))
                                    if !tool.description.isEmpty {
                                        Text(tool.description)
                                            .font(.caption)
                                            .foregroundStyle(FaroColor.ash)
                                    }
                                }
                            }
                        }
                        if let error = errors[server.id] {
                            Text(error).font(.caption).foregroundStyle(FaroColor.error)
                        }
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Herramientas MCP")
            .toolbar {
                ToolbarItem {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddMCPServerSheet { name, url, token in
                    modelContext.insert(MCPServerConfig(name: name, url: url, token: token))
                }
            }
            .alert(
                pendingConfirmation.map { "Conectar con \($0.name)" } ?? "",
                isPresented: Binding(
                    get: { pendingConfirmation != nil },
                    set: { if !$0 { pendingConfirmation = nil } }
                )
            ) {
                Button("Cancelar", role: .cancel) { pendingConfirmation = nil }
                Button("Conectar") { confirmAndEnable() }
            } message: {
                Text("El modelo podrá enviar información a este servidor al usar sus herramientas. Actívalo solo si confías en él.")
            }
        }
    }

    private func toggle(_ server: MCPServerConfig, to newValue: Bool) {
        if newValue && !server.hasBeenConfirmed {
            pendingConfirmation = server
            return
        }
        server.isEnabled = newValue
        apply(server)
    }

    private func confirmAndEnable() {
        guard let server = pendingConfirmation else { return }
        server.hasBeenConfirmed = true
        server.isEnabled = true
        pendingConfirmation = nil
        apply(server)
    }

    /// A live `ChatSession` in ANY open conversation bakes in the tool set
    /// at creation, and MCP servers are shared app-wide — so connecting or
    /// disconnecting one has to drop every cached session, not just one.
    private func apply(_ server: MCPServerConfig) {
        let snapshot = server.snapshot
        let id = server.id
        errors[id] = nil

        if server.isEnabled {
            Task {
                do {
                    toolsByServer[id] = try await MCPConnectionManager.shared.connect(snapshot)
                } catch {
                    errors[id] = error.localizedDescription
                    server.isEnabled = false
                }
                await InferenceEngine.shared.invalidateAllSessions()
            }
        } else {
            toolsByServer[id] = nil
            Task {
                await MCPConnectionManager.shared.disconnect(id)
                await InferenceEngine.shared.invalidateAllSessions()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let server = servers[index]
            let id = server.id
            Task {
                await MCPConnectionManager.shared.disconnect(id)
                await InferenceEngine.shared.invalidateAllSessions()
            }
            // The Keychain item doesn't go with the record on its own.
            server.token = ""
            modelContext.delete(server)
        }
    }
}

private struct AddMCPServerSheet: View {
    let onAdd: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre", text: $name)
                TextField("URL (https://…)", text: $url)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                SecureField("Token (opcional)", text: $token)
            }
            .navigationTitle("Nuevo servidor MCP")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Añadir") {
                        onAdd(name.isEmpty ? url : name, url, token)
                        dismiss()
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
