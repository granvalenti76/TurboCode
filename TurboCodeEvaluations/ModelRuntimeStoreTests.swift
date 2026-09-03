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

    @Test("Reasoning effort keeps persisted composer values stable")
    func reasoningEffortPersistenceContractIsStable() {
        #expect(ReasoningEffort.low.rawValue == "Low")
        #expect(ReasoningEffort.medium.rawValue == "Medium")
        #expect(ReasoningEffort.high.rawValue == "High")
        #expect(ReasoningEffort.xhigh.rawValue == "X-High")
    }
}
