enum DefaultModel {
    /// The fallback when the user has never picked a model. Any valid HF
    /// repo id works here — the engine doesn't consult a fixed registry.
    static let repoID = CuratedModel.all.first?.id ?? "mlx-community/Qwen2.5-0.5B-Instruct-4bit"

    /// The model a new conversation should open with: whatever was picked
    /// last, as long as it's still usable. A remembered repo that has been
    /// deleted (or purged by iOS under disk pressure) would otherwise make
    /// every new conversation start with a download.
    static func resolve(remembered: String, downloaded: [String]) -> String {
        guard !remembered.isEmpty else { return repoID }
        // Apple's model doesn't live on disk, so it's never in the cache listing.
        guard AppleFoundationModel.isAppleFoundation(remembered) || downloaded.contains(remembered) else {
            return repoID
        }
        return remembered
    }
}
