import SwiftUI
import MLXLLM
import MLXVLM

@main
struct FaroApp: App {
    init() {
        // Force both factory singletons to initialize so they register
        // themselves with MLXLMCommon's ModelFactoryRegistry before the
        // first #huggingFaceLoadModelContainer call needs to find one.
        _ = LLMModelFactory.shared
        _ = VLMModelFactory.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [Conversation.self, ChatMessage.self, MCPServerConfig.self])
    }
}
