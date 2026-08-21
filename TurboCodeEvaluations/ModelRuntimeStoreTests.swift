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
}
