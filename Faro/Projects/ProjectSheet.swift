import SwiftUI
import UniformTypeIdentifiers

/// Edits a project's name, instructions, and knowledge documents. Reuses
/// `AttachmentExtractor` for the documents — same PDF/text extraction and
/// per-file character cap the composer's attachments already use.
struct ProjectSheet: View {
    @Bindable var project: Project

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var showFileImporter = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Nombre del proyecto", text: $project.name)
                }

                Section {
                    TextEditor(text: $project.instructions)
                        .frame(minHeight: 100)
                        .font(.body)
                } header: {
                    Text("Instrucciones")
                } footer: {
                    Text("Se añaden al principio de cada conversación del proyecto.")
                }

                Section {
                    if project.documents.isEmpty {
                        Text("Sin documentos todavía.")
                            .font(.footnote)
                            .foregroundStyle(FaroColor.ash)
                    }
                    ForEach(project.documents) { document in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.fileName).lineLimit(1)
                            Text(documentCaption(for: document))
                                .font(.caption)
                                .foregroundStyle(FaroColor.ash)
                        }
                    }
                    .onDelete { offsets in
                        project.documents.remove(atOffsets: offsets)
                    }
                    Button("Añadir archivo") { showFileImporter = true }
                } header: {
                    Text("Conocimiento")
                } footer: {
                    knowledgeFooter
                }
            }
            .scrollContentBackground(.hidden)
            .background(FaroColor.ink)
            .tint(FaroColor.lamp)
            .navigationTitle(project.name.isEmpty ? "Proyecto" : project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") {
                        try? modelContext.save()
                        invalidateSessions()
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: AttachmentExtractor.fileTypes,
                allowsMultipleSelection: true,
                onCompletion: handlePickedFiles
            )
            .alert(
                "No se pudo añadir el archivo",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("Aceptar", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func documentCaption(for document: ProjectDocument) -> String {
        let count = "\(document.text.count) caracteres"
        return document.wasTruncated ? count + " · truncado" : count
    }

    private var knowledgeFooter: some View {
        let count = project.knowledgeCharacterCount
        let limit = Project.knowledgeCharacterLimit
        return Text("\(count.formatted()) de \(limit.formatted()) caracteres")
            .foregroundStyle(count > limit ? FaroColor.error : FaroColor.ash)
    }

    private func handlePickedFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            do {
                let extracted = try AttachmentExtractor.extractSecurityScoped(url)
                project.documents.append(
                    ProjectDocument(fileName: extracted.fileName, text: extracted.text, wasTruncated: extracted.wasTruncated)
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// `InferenceEngine` bakes `instructions:` into the session at creation,
    /// so a project edit needs every member conversation's live session
    /// dropped — otherwise the next turn would still answer from the old
    /// instructions/knowledge.
    private func invalidateSessions() {
        let ids = project.conversations.map(\.id)
        Task {
            for id in ids {
                await InferenceEngine.shared.invalidateSession(conversationID: id)
            }
        }
    }
}
