import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var focused: Bool
    @State private var showFileImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachment = viewModel.pendingAttachment {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text(attachment.fileName).lineLimit(1)
                    Button {
                        viewModel.removeAttachment()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(FaroColor.ash)
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showFileImporter = true
                } label: {
                    Image(systemName: "paperclip")
                        .foregroundStyle(FaroColor.ash)
                        .frame(width: 34, height: 34)
                }

                TextField("Pregunta lo que quieras", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(FaroColor.inkRaised, in: .rect(cornerRadius: 18))
                    .focused($focused)
                    .onSubmit(send)

                Button {
                    if viewModel.isGenerating { viewModel.cancel() } else { send() }
                } label: {
                    Image(systemName: viewModel.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        // Dark icon only reads against the bright fill;
                        // on the dim inactive fill it drops to ~1.8:1
                        // contrast (should stay above 4.5:1), so the
                        // icon color follows the background's lightness.
                        .foregroundStyle(canSend ? FaroColor.ink : FaroColor.ash)
                        .frame(width: 34, height: 34)
                        .background(canSend ? FaroColor.beamCore : FaroColor.ash.opacity(0.3), in: .circle)
                }
                .disabled(!viewModel.isGenerating && !canSend)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, .commaSeparatedText, .text],
            onCompletion: handlePickedFile
        )
    }

    private var canSend: Bool {
        viewModel.isGenerating
            || viewModel.pendingAttachment != nil
            || !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard !viewModel.isGenerating else { return }
        viewModel.send()
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        viewModel.attach(url: url)
    }
}
