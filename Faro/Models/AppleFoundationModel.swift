import Foundation

/// Apple's own on-device language model, offered alongside the MLX repos.
///
/// It isn't a Hugging Face repo and never touches `HubCache`, so it needs a
/// reserved id that every download/preflight path skips. Kept free of any
/// `FoundationModels` import on purpose: the id is referenced all over the
/// app, while the framework itself is confined to `AppleFoundationEngine`.
enum AppleFoundationModel {
    static let id = "apple/foundation"
    static let displayName = "Apple Foundation"

    static func isAppleFoundation(_ modelID: String) -> Bool { modelID == id }
}
