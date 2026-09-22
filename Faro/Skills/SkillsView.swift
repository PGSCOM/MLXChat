import SwiftUI
import UniformTypeIdentifiers

struct SkillsView: View {
    @State private var skills = SkillStore.all
    @State private var editingSkill: Skill?
    @State private var showAddSheet = false
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                if skills.isEmpty {
                    Text("Añade una skill con instrucciones que el modelo pueda usar en tus conversaciones.")
                        .foregroundStyle(FaroColor.ash)
                }
                ForEach(skills) { skill in
                    Section {
                        Button {
                            editingSkill = skill
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(FaroColor.bone)
                                if !skill.summary.isEmpty {
                                    Text(skill.summary)
                                        .font(.footnote)
                                        .foregroundStyle(FaroColor.ash)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Picker(
                            "Modo",
                            selection: Binding(
                                get: { skill.mode },
                                set: { setMode($0, for: skill) }
                            )
                        ) {
                            ForEach(SkillMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                    }
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Skills")
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label("Nueva skill", systemImage: "plus")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label("Importar SKILL.md", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editingSkill) { skill in
                SkillEditor(skill: skill) { updated in
                    save(updated)
                } onDelete: {
                    delete(skill)
                }
            }
            .sheet(isPresented: $showAddSheet) {
                SkillEditor(skill: Skill(name: "", summary: "", instructions: "")) { new in
                    save(new)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .text]) { result in
                importSkill(from: result)
            }
            .alert(
                "No se pudo importar",
                isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
            ) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func setMode(_ mode: SkillMode, for skill: Skill) {
        var updated = skill
        updated.mode = mode
        save(updated)
    }

    private func save(_ skill: Skill) {
        var all = SkillStore.all
        if let index = all.firstIndex(where: { $0.id == skill.id }) {
            all[index] = skill
        } else {
            all.append(skill)
        }
        SkillStore.all = all
        skills = all
    }

    private func delete(_ skill: Skill) {
        var all = SkillStore.all
        all.removeAll { $0.id == skill.id }
        SkillStore.all = all
        skills = all
        editingSkill = nil
    }

    private func delete(at offsets: IndexSet) {
        var all = SkillStore.all
        all.remove(atOffsets: offsets)
        SkillStore.all = all
        skills = all
    }

    private func importSkill(from result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let fallbackName = url.deletingPathExtension().lastPathComponent
            let skill = SkillStore.parse(skillMarkdown: text, fallbackName: fallbackName)
            save(skill)
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct SkillEditor: View {
    @Environment(\.dismiss) private var dismiss
    let original: Skill
    let onSave: (Skill) -> Void
    var onDelete: (() -> Void)?

    @State private var name: String
    @State private var summary: String
    @State private var instructions: String

    init(skill: Skill, onSave: @escaping (Skill) -> Void, onDelete: (() -> Void)? = nil) {
        self.original = skill
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: skill.name)
        _summary = State(initialValue: skill.summary)
        _instructions = State(initialValue: skill.instructions)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Ej. Revisión de código", text: $name)
                }
                Section {
                    TextField("Cuándo debe usarse", text: $summary, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Descripción")
                } footer: {
                    Text("Esto es lo que lee el modelo para decidir si la usa.")
                }
                Section("Instrucciones") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 160)
                }
                if onDelete != nil {
                    Section {
                        Button("Eliminar skill", role: .destructive) {
                            onDelete?()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(original.name.isEmpty ? "Nueva skill" : "Editar skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        var updated = original
                        updated.name = name
                        updated.summary = summary
                        updated.instructions = instructions
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
