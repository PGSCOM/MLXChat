import Foundation
import SwiftData

/// "Restablecer Faro": back to what a fresh install sees. Deleting the
/// downloaded models is the caller's choice — gigabytes that would only
/// be fetched again.
@MainActor
enum AppReset {
    static func run(in context: SwiftData.ModelContext, deletingModels: Bool) async {
        let conversationIDs = Set(((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).map(\.id))
        let serverIDs = ((try? context.fetch(FetchDescriptor<MCPServerConfig>())) ?? []).map(\.id)

        // Whatever could still write into, serve from or call out with
        // what's about to go is stopped first. The server stays off until
        // switched on again, as on every launch, and picks up the new token.
        await ChatViewModel.prepareForDeletion(conversationIDs)
        APIServer.shared.stop()
        for id in serverIDs {
            await MCPConnectionManager.shared.disconnect(id)
        }

        try? eraseStore(in: context)
        for key in AppSettings.keys + ServerSettings.keys + VoiceSettings.keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        Keychain.deleteAll()

        guard deletingModels else { return }
        for id in ModelCacheStore.downloadedIDs() {
            try? ModelCacheStore.delete(id)
            await InferenceEngine.shared.evictContainer(modelID: id)
        }
    }

    /// Every record in the store. Messages are deleted outright as well as
    /// through their conversation's cascade, so one that somehow lost its
    /// conversation can't outlive a reset.
    static func eraseStore(in context: SwiftData.ModelContext) throws {
        try deleteAll(ChatMessage.self, in: context)
        try deleteAll(Conversation.self, in: context)
        try deleteAll(Project.self, in: context)
        try deleteAll(MCPServerConfig.self, in: context)
        try context.save()
    }

    private static func deleteAll<T: PersistentModel>(_: T.Type, in context: SwiftData.ModelContext) throws {
        for model in try context.fetch(FetchDescriptor<T>()) {
            context.delete(model)
        }
    }
}
