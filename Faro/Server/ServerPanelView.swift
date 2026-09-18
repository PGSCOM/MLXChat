import SwiftUI
import UIKit

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
                    .tint(FaroColor.lamp)
                } footer: {
                    Text("El servidor solo responde mientras Faro está abierto en primer plano.")
                }

                if server.isRunning {
                    Section("Conexión") {
                        if let interface = selectedInterface ?? interfaces.first {
                            CopyableValue(title: "Dirección", value: "http://\(interface.ip):\(ServerSettings.port)")
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
                            CopyableValue(title: "Bearer", value: ServerSettings.bearerToken)
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
                        Text(error).foregroundStyle(FaroColor.error)
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

/// An address or a token is meant to be typed into another device, so it
/// gets a copy action rather than only being selectable.
private struct CopyableValue: View {
    let title: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(FaroColor.ash)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                UIPasteboard.general.string = value
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? FaroColor.lamp : FaroColor.ash)
            .accessibilityLabel("Copiar \(title)")
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
