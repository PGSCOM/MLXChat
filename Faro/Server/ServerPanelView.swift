import SwiftUI

struct ServerPanelView: View {
    @State private var server = APIServer.shared
    @State private var interfaces: [LANAddress.Interface] = []
    @State private var selectedInterface: LANAddress.Interface?
    @State private var showToken = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(
                        "Servidor activo",
                        isOn: Binding(
                            get: { server.isRunning },
                            set: { $0 ? server.start() : server.stop() }
                        )
                    )
                    .tint(FaroColor.beamCore)
                } footer: {
                    Text("El servidor solo responde mientras Faro está abierto en primer plano.")
                }

                if server.isRunning {
                    Section("Conexión") {
                        if let interface = selectedInterface ?? interfaces.first {
                            LabeledContent("Dirección") {
                                Text("http://\(interface.ip):\(ServerSettings.port)")
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text("No se encontró ninguna red activa.")
                                .foregroundStyle(FaroColor.ash)
                        }
                        if interfaces.count > 1 {
                            Picker("Interfaz", selection: $selectedInterface) {
                                ForEach(interfaces) { interface in
                                    Text("\(interface.name) · \(interface.ip)")
                                        .tag(Optional(interface))
                                }
                            }
                        }
                    }

                    Section("Token") {
                        if showToken {
                            Text(ServerSettings.bearerToken)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Button("Mostrar token") { showToken = true }
                        }
                    }

                    Section("Actividad reciente") {
                        if server.requestLog.isEmpty {
                            Text("Sin peticiones todavía.")
                                .foregroundStyle(FaroColor.ash)
                        } else {
                            ForEach(Array(server.requestLog.suffix(10).reversed()), id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(FaroColor.ash)
                            }
                        }
                    }
                }

                if let error = server.lastError {
                    Section {
                        Text(error).foregroundStyle(FaroColor.beamFar)
                    }
                }
            }
            .navigationTitle("Servidor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .onAppear { interfaces = LANAddress.activeIPv4Addresses() }
        }
    }
}
