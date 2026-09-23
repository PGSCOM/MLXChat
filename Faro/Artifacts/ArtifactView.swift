import SwiftUI
import WebKit

struct ArtifactCard: View {
    let artifact: Artifact
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(FaroColor.lamp)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(FaroColor.bone)
                        .lineLimit(1)
                    Text("\(artifact.language.isEmpty ? "texto" : artifact.language) · \(artifact.lineCount) líneas")
                        .font(.caption)
                        .foregroundStyle(FaroColor.ash)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FaroColor.ash)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .faroCard()
        .sheet(isPresented: $showSheet) {
            ArtifactSheet(artifact: artifact)
        }
    }

    private var icon: String {
        switch artifact.language.lowercased() {
        case "html", "svg": "safari"
        case "markdown", "md": "doc.text"
        case "json", "yaml", "yml": "curlybraces"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }
}

private struct ArtifactSheet: View {
    let artifact: Artifact
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .preview

    private enum Tab { case code, preview }

    var body: some View {
        NavigationStack {
            Group {
                if artifact.isPreviewable, tab == .preview {
                    ArtifactWebView(html: previewHTML)
                } else {
                    ScrollView {
                        Text(artifact.content)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(FaroColor.bone)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .background(FaroColor.ink)
            .navigationTitle(artifact.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                if artifact.isPreviewable {
                    ToolbarItem(placement: .principal) {
                        Picker("", selection: $tab) {
                            Text("Vista previa").tag(Tab.preview)
                            Text("Código").tag(Tab.code)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button {
                        UIPasteboard.general.string = artifact.content
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copiar")

                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Compartir")
                    }
                }
            }
            .onAppear { if !artifact.isPreviewable { tab = .code } }
        }
    }

    private var previewHTML: String {
        artifact.language.lowercased() == "svg"
            ? "<html><body style=\"margin:0\">\(artifact.content)</body></html>"
            : artifact.content
    }

    /// Written to the temp directory so `ShareLink` can hand off a real
    /// file — "Save to Files", AirDrop and Mail all in one, for less code
    /// than a `FileDocument` + `.fileExporter`.
    private var fileURL: URL? {
        let name = artifact.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let fileName = (name.isEmpty ? "artifact" : name) + "." + artifact.fileExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try artifact.content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// Renders HTML/SVG offline, no network. Every navigation away from the
/// initial load is cancelled — the app's promise is "everything happens on
/// this device", and a model-generated `<img src="https://…">` can't be
/// allowed to break that.
private struct ArtifactWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loadedInitial = false

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard loadedInitial else {
                loadedInitial = true
                return .allow
            }
            return .cancel
        }
    }
}
