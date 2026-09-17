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
    /// Bumped after a delete to force `downloadedModels` (a disk read, not
    /// `@State`) to re-run — nothing else changes when a file disappears.
    @State private var refreshToken = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Descargados") {
                    if downloadedModels.isEmpty {
                        Text("Ningún modelo descargado todavía.")
                            .font(.caption)
                            .foregroundStyle(FaroColor.ash)
                    }
                    ForEach(downloadedModels) { model in
                        DownloadedModelRow(
                            title: displayName(for: model.id),
                            sizeBytes: model.sizeBytes,
                            isSelected: model.id == currentModelID,
                            onSelect: { select(model.id) },
                            onDelete: { delete(model.id) }
                        )
                    }
                }

                Section("Recomendados") {
                    ForEach(CuratedModel.all) { model in
                        ModelRow(
                            id: model.id,
                            title: model.displayName,
                            subtitle: subtitle(for: model),
                            isSelected: model.id == currentModelID,
                            coordinator: coordinator,
                            onSelect: { select(model.id) }
                        )
                    }
                }

                Section("Buscar en Hugging Face") {
                    TextField("Nombre del modelo", text: $query)
                        .textInputAutocapitalization(.never)
                    if isSearching {
                        ProgressView().tint(FaroColor.beamCore)
                    } else if let searchError {
                        Text(searchError)
                            .font(.caption)
                            .foregroundStyle(FaroColor.ash)
                    }
                    ForEach(results) { result in
                        ModelRow(
                            id: result.id,
                            title: result.id,
                            subtitle: "\(result.downloads) descargas",
                            isSelected: result.id == currentModelID,
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
            .task(id: query) {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    results = []
                    searchError = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                isSearching = true
                searchError = nil
                do {
                    results = try await HuggingFaceSearch.search(trimmed)
                } catch {
                    searchError = error.localizedDescription
                }
                isSearching = false
            }
        }
    }

    /// Reads the cache fresh every render — a plain disk listing, not
    /// `@State`, so it can never go stale. Also reads `coordinator.status`
    /// so this view (not just the row that owns it) re-renders when any
    /// download finishes and a new model lands on disk.
    private var downloadedModels: [ModelCacheStore.DownloadedModel] {
        _ = coordinator.status.count
        _ = refreshToken
        return ModelCacheStore.downloadedModels()
    }

    private func displayName(for id: String) -> String {
        CuratedModel.all.first { $0.id == id }?.displayName ?? id
    }

    private func subtitle(for model: CuratedModel) -> String {
        var parts = [String(format: "%.1f GB", model.approxSizeGB)]
        if model.isVision { parts.append("Visión") }
        if model.isRecommended { parts.append("Recomendado") }
        return parts.joined(separator: " · ")
    }

    private func select(_ id: String) {
        onSelect(id)
        dismiss()
    }

    private func delete(_ id: String) {
        try? ModelCacheStore.delete(id)
        Task { await InferenceEngine.shared.evictContainer(modelID: id) }
        refreshToken += 1
    }
}

private struct DownloadedModelRow: View {
    let title: String
    let sizeBytes: Int64
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(sizeBytes.formatted(.byteCount(style: .memory)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(FaroColor.ash)
                }
            }
            .buttonStyle(.plain)
            .disabled(isSelected)

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(FaroColor.beamCore)
            } else {
                // Deleting the model in use would pull the cache out from
                // under a live conversation, so that's the only state
                // without a trash icon.
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(FaroColor.error)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ModelRow: View {
    let id: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let coordinator: ModelDownloadCoordinator
    let onSelect: () -> Void

    var body: some View {
        Button(action: primaryAction) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(FaroColor.ash)
                    if let status = coordinator.status[id] {
                        Text(ModelLoadStatusFormatter.line(status))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(FaroColor.ash)
                    }
                    if let error = coordinator.errors[id] {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(FaroColor.error)
                    }
                }
                Spacer()
                trailing
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var trailing: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FaroColor.beamCore)
        } else if let status = coordinator.status[id] {
            ProgressView(value: status.fraction)
                .frame(width: 60)
                .tint(FaroColor.beamCore)
        } else if ModelCacheStore.isDownloaded(id) {
            Text("Usar")
                .font(.caption.weight(.medium))
                .foregroundStyle(FaroColor.beamCore)
        } else {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(FaroColor.ash)
        }
    }

    private func primaryAction() {
        if isSelected {
            return
        } else if ModelCacheStore.isDownloaded(id) {
            onSelect()
        } else if coordinator.status[id] == nil {
            coordinator.download(id: id)
        }
    }
}
