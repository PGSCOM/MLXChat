import SwiftUI

struct ModelBrowserView: View {
    let currentModelID: String
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    private let coordinator = ModelDownloadCoordinator.shared
    @State private var query = ""
    @State private var results: [HuggingFaceSearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var downloaded: [ModelCacheStore.DownloadedModel] = []
    /// What each downloaded model can actually do, read straight off disk —
    /// keyed alongside `downloaded` so a model that doesn't admit reasoning
    /// or tools says so here too, not just before it's downloaded.
    @State private var capabilities: [String: ModelCapabilityProbe.Capabilities] = [:]
    @State private var pendingDeletion: ModelCacheStore.DownloadedModel?
    @State private var pendingDeleteAll = false
    @State private var appleIsAvailable = false

    private var downloadedIDs: Set<String> { Set(downloaded.map(\.id)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AppleFoundationRow(
                        isSelected: currentModelID == AppleFoundationModel.id,
                        isAvailable: appleIsAvailable,
                        onSelect: { select(AppleFoundationModel.id) }
                    )
                } header: {
                    Text("Sistema")
                } footer: {
                    Text(appleIsAvailable
                         ? "Ya está en el dispositivo: no ocupa espacio ni hay que descargarlo. Solo texto."
                         : "Requiere Apple Intelligence activado en Ajustes.")
                }

                Section {
                    if downloaded.isEmpty {
                        Text("Ningún modelo descargado todavía.")
                            .font(.footnote)
                            .foregroundStyle(FaroColor.ash)
                    }
                    ForEach(downloaded) { model in
                        DownloadedModelRow(
                            title: displayName(for: model.id),
                            repoID: model.id,
                            sizeBytes: model.sizeBytes,
                            warnings: capabilities[model.id]?.warnings ?? [],
                            isSelected: model.id == currentModelID,
                            onSelect: { select(model.id) },
                            onDelete: { pendingDeletion = model }
                        )
                    }
                } header: {
                    Text("En este dispositivo")
                } footer: {
                    if !downloaded.isEmpty {
                        HStack {
                            Text("Almacenamiento usado: \(totalDownloadedBytes.formatted(.byteCount(style: .memory)))")
                            Spacer(minLength: 8)
                            if downloaded.contains(where: { $0.id != currentModelID }) {
                                Button("Eliminar todos") { pendingDeleteAll = true }
                                    .foregroundStyle(FaroColor.error)
                            }
                        }
                    }
                }

                Section("Recomendados") {
                    ForEach(CuratedModel.all) { model in
                        ModelRow(
                            id: model.id,
                            title: model.displayName,
                            subtitle: subtitle(for: model),
                            isSelected: model.id == currentModelID,
                            isDownloaded: downloadedIDs.contains(model.id),
                            coordinator: coordinator,
                            onSelect: { select(model.id) }
                        )
                    }
                }

                Section("Buscar en Hugging Face") {
                    TextField("Nombre del modelo", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if isSearching {
                        ProgressView().tint(FaroColor.lamp)
                    } else if let searchError {
                        Text(searchError)
                            .font(.caption)
                            .foregroundStyle(FaroColor.error)
                    } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, results.isEmpty {
                        Text("Sin resultados.")
                            .font(.footnote)
                            .foregroundStyle(FaroColor.ash)
                    }
                    ForEach(results) { result in
                        ModelRow(
                            id: result.id,
                            title: result.id,
                            subtitle: "\(result.downloads.formatted()) descargas",
                            isSelected: result.id == currentModelID,
                            isDownloaded: downloadedIDs.contains(result.id),
                            coordinator: coordinator,
                            onSelect: { select(result.id) }
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(FaroColor.ink)
            .navigationTitle("Modelos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            // Re-scans on appear, and again when a download starts or
            // finishes — the only things that change what's on disk while
            // this list is open.
            .task(id: coordinator.status.isEmpty) { await refreshDownloaded() }
            .task { appleIsAvailable = AppleFoundationEngine.isAvailable }
            .task(id: query) { await runSearch() }
            .confirmationDialog(
                pendingDeletion.map { "¿Borrar \(displayName(for: $0.id))?" } ?? "",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Borrar del dispositivo", role: .destructive) {
                    if let model = pendingDeletion { delete(model.id) }
                    pendingDeletion = nil
                }
                Button("Cancelar", role: .cancel) { pendingDeletion = nil }
            } message: {
                if let model = pendingDeletion {
                    Text("Se liberarán \(model.sizeBytes.formatted(.byteCount(style: .memory))). Habrá que descargarlo otra vez para usarlo.")
                }
            }
            .confirmationDialog(
                "¿Eliminar todos los modelos descargados?",
                isPresented: $pendingDeleteAll,
                titleVisibility: .visible
            ) {
                Button("Eliminar todos", role: .destructive) { deleteAll() }
                Button("Cancelar", role: .cancel) { pendingDeleteAll = false }
            } message: {
                Text(deletableBytes == totalDownloadedBytes
                     ? "Se liberarán \(deletableBytes.formatted(.byteCount(style: .memory)))."
                     : "Se liberarán \(deletableBytes.formatted(.byteCount(style: .memory))). El modelo en uso se conserva.")
            }
        }
    }

    private var totalDownloadedBytes: Int64 {
        downloaded.reduce(0) { $0 + $1.sizeBytes }
    }

    /// The model in use is never deleted — pulling its cache out from
    /// under a live conversation is the same rule the per-row delete
    /// already enforces.
    private var deletableBytes: Int64 {
        downloaded.filter { $0.id != currentModelID }.reduce(0) { $0 + $1.sizeBytes }
    }

    /// The cache listing walks every blob on disk to add up sizes, and
    /// reading each model's chat template can mean a ~1 MB file read, so
    /// both run off the main actor instead of on every redraw of this list.
    private func refreshDownloaded() async {
        let (models, caps) = await Task.detached(priority: .utility) {
            let models = ModelCacheStore.downloadedModels()
            var caps: [String: ModelCapabilityProbe.Capabilities] = [:]
            for model in models {
                caps[model.id] = ModelCapabilityProbe.onDisk(modelID: model.id)
            }
            return (models, caps)
        }.value
        downloaded = models
        capabilities = caps
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            searchError = nil
            isSearching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        isSearching = true
        searchError = nil
        do {
            results = try await HuggingFaceSearch.search(trimmed)
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    private func displayName(for id: String) -> String {
        CuratedModel.all.first { $0.id == id }?.displayName ?? id
    }

    private func subtitle(for model: CuratedModel) -> String {
        var parts = [String(format: "%.1f GB", model.approxSizeGB)]
        if model.isVision { parts.append("Visión") }
        if model.supportsReasoning { parts.append("Razona") }
        if model.isRecommended { parts.append("Recomendado") }
        return parts.joined(separator: " · ")
    }

    private func select(_ id: String) {
        onSelect(id)
        dismiss()
    }

    private func deleteAll() {
        pendingDeleteAll = false
        for model in downloaded where model.id != currentModelID {
            delete(model.id)
        }
    }

    private func delete(_ id: String) {
        try? ModelCacheStore.delete(id)
        Task {
            await InferenceEngine.shared.evictContainer(modelID: id)
            await refreshDownloaded()
        }
    }
}

private struct DownloadedModelRow: View {
    let title: String
    let repoID: String
    let sizeBytes: Int64
    let warnings: [String]
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(FaroColor.bone)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(FaroColor.ash)
                        .lineLimit(1)
                    if let capitalizedWarning {
                        Text(capitalizedWarning)
                            .font(.caption2)
                            .foregroundStyle(FaroColor.lamp)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(isSelected)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FaroColor.lamp)
            } else {
                // Deleting the model in use would pull the cache out from
                // under a live conversation, so that's the only state
                // without a delete action.
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(FaroColor.error)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Borrar \(title)")
            }
        }
    }

    /// The display name can already be the repo id (anything outside the
    /// curated list), so don't print it twice.
    private var subtitle: String {
        let size = sizeBytes.formatted(.byteCount(style: .memory))
        return title == repoID ? size : "\(size) · \(repoID)"
    }

    private var capitalizedWarning: String? {
        guard !warnings.isEmpty else { return nil }
        let joined = warnings.joined(separator: " · ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

private struct ModelRow: View {
    let id: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let isDownloaded: Bool
    let coordinator: ModelDownloadCoordinator
    let onSelect: () -> Void

    var body: some View {
        // Only the cancel button gets pulled out as its own tap target —
        // everything else (including the download arrow / checkmark /
        // "Usar") stays inside the row-wide button, same as before the
        // cancel button existed. Nesting a real button inside another
        // button's label is what actually breaks tapping in SwiftUI, not
        // having a wide tappable row.
        HStack(spacing: 12) {
            Button(action: primaryAction) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .foregroundStyle(FaroColor.bone)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(FaroColor.ash)
                        if let status = coordinator.status[id] {
                            Text(ModelLoadStatusFormatter.line(status))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(FaroColor.ash)
                        }
                        if let warning = coordinator.warnings[id] {
                            Text(warning)
                                .font(.caption2)
                                .foregroundStyle(FaroColor.lamp)
                        }
                        if let error = coordinator.errors[id] {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(FaroColor.error)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    trailing
                }
            }
            .buttonStyle(.plain)

            if !isSelected, coordinator.status[id] != nil {
                Button {
                    coordinator.cancel(id: id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FaroColor.ash)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancelar descarga de \(title)")
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FaroColor.lamp)
        } else if let status = coordinator.status[id] {
            ProgressView(value: status.fraction)
                .frame(width: 56)
                .tint(FaroColor.lamp)
        } else if isDownloaded {
            Text("Usar")
                .font(.caption.weight(.medium))
                .foregroundStyle(FaroColor.lamp)
        } else {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FaroColor.ash)
        }
    }

    private func primaryAction() {
        guard !isSelected else { return }
        if isDownloaded {
            onSelect()
        } else if coordinator.status[id] == nil {
            coordinator.download(id: id)
        }
    }
}


/// Apple's model has no size, no download and no progress — every other
/// row's chrome would be a lie here, so it gets its own plain row.
private struct AppleFoundationRow: View {
    let isSelected: Bool
    let isAvailable: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppleFoundationModel.displayName)
                        .foregroundStyle(isAvailable ? FaroColor.bone : FaroColor.ash)
                    Text(isAvailable ? "Modelo de Apple en el dispositivo" : "Apple Intelligence no está activado")
                        .font(.caption)
                        .foregroundStyle(FaroColor.ash)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FaroColor.lamp)
                } else if isAvailable {
                    Text("Usar")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FaroColor.lamp)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable || isSelected)
    }
}
