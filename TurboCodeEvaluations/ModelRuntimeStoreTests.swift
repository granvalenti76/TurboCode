import Testing
@testable import TurboCode

@Suite("Model runtime configuration")
struct ModelRuntimeStoreTests {
    @Test("Initial Llama selection preserves the configured server URL")
    func initialLlamaSelectionUsesPersistedURL() {
        let configuredLlama = RemoteModelConfig(
            id: "llama",
            name: "Remote Llama",
            url: "http://192.168.1.120:8080/v1",
            modelName: "local-model",
            temperature: 0.6
        )

        let selected = ModelRuntimeStore.initialRemoteModel(
            from: [configuredLlama],
            selectedID: "llama"
        )

        #expect(selected.url == configuredLlama.url)
    }

    @Test("Conversation title normalization stays bounded and optional")
    func conversationTitleNormalizationIsDeterministic() {
        #expect(
            ModelRuntimeStore.normalizedConversationTitle("  \"Fix the sidebar\"  ")
                == "Fix the sidebar"
        )
        #expect(
            ModelRuntimeStore.normalizedConversationTitle("   \n") == nil
        )
        #expect(
            ModelRuntimeStore.normalizedConversationTitle(String(repeating: "x", count: 80))?.count
                == 60
        )
    }
}
