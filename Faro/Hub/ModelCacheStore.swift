import Foundation
import HuggingFace

/// Reads and deletes models already on disk in `HubCache` (the same cache
/// `#huggingFaceLoadModelContainer` uses by default — verified against
/// `HubClient`'s `cache: HubCache? = .default` and the macro's own
/// `HuggingFace.HubCache.default` reference). The disk is the source of
/// truth, not a remembered flag: `InferenceEngine.swift` already flags that
/// iOS can purge this cache under disk pressure, which would make an
/// in-memory "downloaded" flag lie.
enum ModelCacheStore {
    struct DownloadedModel: Identifiable, Sendable {
        let id: String
        let sizeBytes: Int64
    }

    private static let prefix = "models--"

    /// Every model repo currently cached on disk, discovered by scanning
    /// the cache root — not limited to the curated list or search results.
    static func downloadedModels() -> [DownloadedModel] {
        let cache = HubCache.default
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cache.cacheDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        return entries.compactMap { url -> DownloadedModel? in
            guard let id = repoID(fromDirectoryName: url.lastPathComponent) else { return nil }
            return DownloadedModel(id: id, sizeBytes: directorySize(url))
        }.sorted { $0.id < $1.id }
    }

    static func isDownloaded(_ modelID: String) -> Bool {
        guard let id = Repo.ID(rawValue: modelID) else { return false }
        return FileManager.default.fileExists(
            atPath: HubCache.default.repoDirectory(repo: id, kind: .model).path
        )
    }

    static func delete(_ modelID: String) throws {
        guard let id = Repo.ID(rawValue: modelID) else { return }
        let cache = HubCache.default
        // Metadata lives outside the repo directory (see HubCache docs); best
        // effort, the repo directory below is the one that actually matters.
        try? FileManager.default.removeItem(at: cache.metadataDirectory(repo: id, kind: .model))
        try FileManager.default.removeItem(at: cache.repoDirectory(repo: id, kind: .model))
    }

    /// Reverses `HubCache`'s `"models--<namespace>--<name>"` directory naming.
    /// Splits on the first `--` only, since HF namespaces don't contain one.
    /// Rejects anything that isn't a model repo (`datasets--...`, `spaces--...`).
    /// Not `private`: covered directly by `ModelCacheStoreTests` (no need to
    /// fake a directory tree on disk to test pure string parsing).
    static func repoID(fromDirectoryName name: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let remainder = name.dropFirst(prefix.count)
        guard let separator = remainder.range(of: "--") else { return nil }
        let namespace = remainder[remainder.startIndex..<separator.lowerBound]
        let repoName = remainder[separator.upperBound...]
        guard !namespace.isEmpty, !repoName.isEmpty else { return nil }
        return "\(namespace)/\(repoName)"
    }

    /// Blobs hold the real content; snapshot entries are symlinks to them,
    /// so summing only regular files avoids double-counting.
    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(keys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
