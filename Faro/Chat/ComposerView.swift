import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import UIKit

struct ComposerView: View {
    @Bindable var viewModel: ChatViewModel
    @FocusState private var focused: Bool
    @State private var showFileImporter = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var isDropTargeted = false

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
                    .accessibilityLabel("Quitar el archivo")
                }
                .font(.caption)
                .foregroundStyle(FaroColor.ash)
            }

            if let imageData = viewModel.pendingImageData, let thumbnail = UIImage(data: imageData) {
                HStack(spacing: 6) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button {
                        viewModel.removeImage()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Quitar la imagen")
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
                .accessibilityLabel("Adjuntar un archivo")

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo")
                        .foregroundStyle(FaroColor.ash)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Adjuntar una imagen")

                TextField("Pregunta lo que quieras", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(FaroColor.bone)
                    .tint(FaroColor.lamp)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(FaroColor.inkRaised, in: .rect(cornerRadius: 18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(focused ? FaroColor.lamp.opacity(0.5) : FaroColor.edge, lineWidth: 1)
                    }
                    .focused($focused)

                Button {
                    if viewModel.isGenerating { viewModel.cancel() } else { send() }
                } label: {
                    Image(systemName: viewModel.isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        // Dark glyph only reads against the bright fill;
                        // on the dim inactive fill it drops to ~1.8:1
                        // contrast (should stay above 4.5:1), so the
                        // glyph color follows the background's lightness.
                        .foregroundStyle(canSend ? FaroColor.ink : FaroColor.ash)
                        .frame(width: 34, height: 34)
                        .background(canSend ? FaroColor.bone : FaroColor.inkRaised, in: .circle)
                        // The inactive fill is nearly the page colour, so
                        // it keeps an edge to stay visibly a button.
                        .overlay { Circle().strokeBorder(canSend ? .clear : FaroColor.edge, lineWidth: 1) }
                }
                .disabled(!canSend)
                .accessibilityLabel(viewModel.isGenerating ? "Detener la respuesta" : "Enviar")
            }
        }
        // A hairline highlight while something hovers, so the drop target
        // reads as live instead of doing nothing visibly until it lands.
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(FaroColor.lamp, lineWidth: 1.5)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: AttachmentExtractor.fileTypes,
            onCompletion: handlePickedFile
        )
        .onChange(of: pickerItem) {
            guard let pickerItem else { return }
            Task {
                if let data = try? await pickerItem.loadTransferable(type: Data.self) {
                    viewModel.attachImage(data: data)
                }
            }
            self.pickerItem = nil
        }
        .onDrop(of: [.image] + AttachmentExtractor.fileTypes, isTargeted: $isDropTargeted, perform: handleDrop)
    }

    /// Also true while generating: the same button becomes "stop", and it
    /// has to stay live for that.
    private var canSend: Bool {
        viewModel.isGenerating
            || viewModel.pendingAttachment != nil
            || viewModel.pendingImageData != nil
            || !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard !viewModel.isGenerating else { return }
        viewModel.send()
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        viewModel.attach(url: url)
    }

    /// Images take priority (a photo dragged from Photos also advertises
    /// generic file types); everything else goes through the same
    /// extractor the file picker uses.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in viewModel.attachImage(data: data) }
            }
            return true
        }

        for type in AttachmentExtractor.fileTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // Only valid synchronously here — the item provider may
                // delete its temp file the moment this closure returns.
                guard let url else { return }
                do {
                    let attachment = try AttachmentExtractor.extractText(from: url)
                    Task { @MainActor in viewModel.setAttachment(attachment) }
                } catch {
                    Task { @MainActor in viewModel.errorMessage = error.localizedDescription }
                }
            }
            return true
        }

        return false
    }
}
