import Foundation
import Testing
@testable import TurboCode

/// Answers fixed bodies by URL so discovery is tested without sockets or a
/// model running on the developer's Mac. Unknown URLs behave like a closed port.
private struct StubHTTPClient: OnboardingHTTPClient {
    var responses: [String: (Int, String)] = [:]
    var postResponse: (Int, String)?

    func get(_ url: URL, timeout: TimeInterval) async -> (status: Int, body: Data)? {
        responses[url.absoluteString].map { ($0.0, Data($0.1.utf8)) }
    }

    func postJSON(_ url: URL, body: Data, timeout: TimeInterval) async -> (status: Int, body: Data)? {
        postResponse.map { ($0.0, Data($0.1.utf8)) }
    }
}

@MainActor
@Suite("First-launch model setup")
struct FirstLaunchModelSetupTests {
    private let modelsListing = #"{"object":"list","data":[{"id":"/models/Qwen3.6-35B-A3B.gguf"}]}"#

    @Test("A server answering /props is recognized as llama-server with its context")
    func recognizesLlamaServer() async {
        let stub = StubHTTPClient(responses: [
            "http://127.0.0.1:8080/v1/models": (200, modelsListing),
            "http://127.0.0.1:8080/props": (200, #"{"default_generation_settings":{"n_ctx":32768},"modalities":{"vision":false}}"#),
        ])
        let server = await LocalModelServerDiscovery(http: stub)
            .probe(baseURL: "http://127.0.0.1:8080/v1", productHint: "LM Studio")

        #expect(server?.kind == .llamaServer)
        #expect(server?.product == "llama-server")
        #expect(server?.contextWindowTokens == 32_768)
        #expect(server?.supportsVision == false)
        #expect(server?.primaryModelID == "/models/Qwen3.6-35B-A3B.gguf")
    }

    @Test("A server without /props is a generic OpenAI-compatible server")
    func recognizesGenericServer() async {
        let stub = StubHTTPClient(responses: [
            "http://127.0.0.1:1234/v1/models": (200, #"{"data":[{"id":"qwen3-coder-30b"}]}"#),
            "http://127.0.0.1:1234/props": (404, ""),
        ])
        let server = await LocalModelServerDiscovery(http: stub)
            .probe(baseURL: "http://127.0.0.1:1234/v1", productHint: "LM Studio")

        #expect(server?.kind == .openAICompatible)
        #expect(server?.product == "LM Studio")
        #expect(server?.contextWindowTokens == nil)
    }

    @Test("Closed ports and empty listings are not reported as servers")
    func ignoresClosedAndEmptyServers() async {
        let stub = StubHTTPClient(responses: [
            "http://127.0.0.1:8000/v1/models": (200, #"{"data":[]}"#),
        ])
        let discovery = LocalModelServerDiscovery(http: stub)

        #expect(await discovery.probe(baseURL: "http://127.0.0.1:8000/v1") == nil)
        #expect(await discovery.probe(baseURL: "http://127.0.0.1:11434/v1") == nil)
    }

    @Test("Typed addresses are normalized to an OpenAI base URL")
    func normalizesTypedAddresses() {
        #expect(LocalModelServerDiscovery.normalizedBaseURL("192.168.1.120:8080") == "http://192.168.1.120:8080/v1")
        #expect(LocalModelServerDiscovery.normalizedBaseURL(" http://host:8080/ ") == "http://host:8080/v1")
        #expect(LocalModelServerDiscovery.normalizedBaseURL("https://host/v1") == "https://host/v1")
        #expect(LocalModelServerDiscovery.normalizedBaseURL("ftp://host") == nil)
        #expect(LocalModelServerDiscovery.normalizedBaseURL("   ") == nil)
    }

    @Test("The tool-call probe distinguishes a call, a text answer and no answer")
    func classifiesToolCallProbe() async {
        let server = DiscoveredModelServer(
            baseURL: "http://127.0.0.1:8080/v1", kind: .llamaServer, product: "llama-server",
            modelIDs: ["m"], contextWindowTokens: 32_768, supportsVision: false
        )
        let called = StubHTTPClient(postResponse: (200, #"{"choices":[{"message":{"tool_calls":[{"id":"1"}]}}]}"#))
        let text = StubHTTPClient(postResponse: (200, #"{"choices":[{"message":{"content":"pong"}}]}"#))
        let silent = StubHTTPClient()

        #expect(await LocalModelServerDiscovery(http: called).probeToolCalling(server: server, modelID: "m") == .passed)
        #expect(await LocalModelServerDiscovery(http: text).probeToolCalling(server: server, modelID: "m") == .failed)
        #expect(await LocalModelServerDiscovery(http: silent).probeToolCalling(server: server, modelID: "m") == .unreachable)
    }

    @Test("llama-server entries take the server context and leave vision to the runtime")
    func buildsLlamaServerEntry() {
        let server = DiscoveredModelServer(
            baseURL: "http://127.0.0.1:8080/v1", kind: .llamaServer, product: "llama-server",
            modelIDs: ["/models/Qwen3.6-35B-A3B.gguf"], contextWindowTokens: 65_536, supportsVision: true
        )
        let model = OnboardingModelConfiguration.localModel(
            server: server, modelID: server.primaryModelID, displayName: "  ", chosenContextWindow: 8_192
        )

        #expect(model.id == "llama")
        #expect(model.name == "Qwen3.6-35B-A3B")
        #expect(model.url == "http://127.0.0.1:8080/v1")
        #expect(model.contextWindowTokens == 65_536)
        #expect(model.supportsVision == nil)
    }

    @Test("Other servers store the chosen context and no vision")
    func buildsGenericEntry() {
        let server = DiscoveredModelServer(
            baseURL: "http://127.0.0.1:1234/v1", kind: .openAICompatible, product: "LM Studio",
            modelIDs: ["qwen3-coder-30b"], contextWindowTokens: nil, supportsVision: nil
        )
        let model = OnboardingModelConfiguration.localModel(
            server: server, modelID: "qwen3-coder-30b", displayName: "Coder", chosenContextWindow: 16_384
        )

        #expect(model.name == "Coder")
        #expect(model.modelName == "qwen3-coder-30b")
        #expect(model.contextWindowTokens == 16_384)
        #expect(model.supportsVision == false)
    }

    // MARK: MLX VLM

    /// A trimmed copy of what mlx_vlm.server's `/health` returned on
    /// 2026-11-18, including its 524K model-maximum context.
    private let mlxHealth = #"""
    {"status":"healthy","loaded_model":"nativ-community/SenseNova-Loop-9B-nvfp4","model_ready":true,
     "loaded_context_size":524288,"effective_context_limit":524288,"apc_enabled":true}
    """#

    @Test("A server whose /health names a loaded model is recognized as MLX VLM with images")
    func recognizesMLXVLM() async {
        let stub = StubHTTPClient(responses: [
            "http://127.0.0.1:8080/v1/models": (200, #"{"data":[{"id":"other/cached-model"},{"id":"nativ-community/SenseNova-Loop-9B-nvfp4"}]}"#),
            "http://127.0.0.1:8080/props": (404, #"{"detail":"Not Found"}"#),
            "http://127.0.0.1:8080/health": (200, mlxHealth),
        ])
        let server = await LocalModelServerDiscovery(http: stub)
            .probe(baseURL: "127.0.0.1:8080", productHint: "llama-server")

        #expect(server?.kind == .mlxVLM)
        #expect(server?.product == "MLX VLM")
        #expect(server?.primaryModelID == "nativ-community/SenseNova-Loop-9B-nvfp4")
        #expect(server?.modelIDs.count == 2)
        #expect(server?.supportsVision == true)
        // The reported 524K is the model's maximum, not what fits in memory.
        #expect(server?.contextWindowTokens == nil)
    }

    @Test("A plain health check is not mistaken for MLX VLM")
    func plainHealthIsGeneric() async {
        let stub = StubHTTPClient(responses: [
            "http://127.0.0.1:1234/v1/models": (200, #"{"data":[{"id":"qwen3-coder-30b"}]}"#),
            "http://127.0.0.1:1234/health": (200, #"{"status":"ok"}"#),
        ])
        let server = await LocalModelServerDiscovery(http: stub)
            .probe(baseURL: "http://127.0.0.1:1234/v1", productHint: "LM Studio")

        #expect(server?.kind == .openAICompatible)
    }

    @Test("MLX VLM entries store the chosen context and images on")
    func buildsMLXEntry() {
        let server = DiscoveredModelServer(
            baseURL: "http://127.0.0.1:8080/v1", kind: .mlxVLM, product: "MLX VLM",
            modelIDs: ["nativ-community/SenseNova-Loop-9B-nvfp4"], contextWindowTokens: nil, supportsVision: true
        )
        let model = OnboardingModelConfiguration.localModel(
            server: server, modelID: server.primaryModelID, displayName: "", chosenContextWindow: nil
        )

        #expect(model.name == "SenseNova-Loop-9B-nvfp4")
        #expect(model.contextWindowTokens == 32_768)
        #expect(model.supportsVision == true)
    }

    // MARK: Settings → Local Server

    @Test("Applying a server from Settings changes only the connection fields")
    func applyingLocalServerKeepsTunedFields() {
        var local = RemoteModelConfig(
            id: "llama", name: "sensenova-9b", url: "http://localhost:8080/v1",
            modelName: "nativ-community/SenseNova-Loop-9B-nvfp4", temperature: 0.3,
            reasoningConfiguration: .requestTokenBudget, contextWindowTokens: 65_536
        )
        local.enabled = false
        let premium = RemoteModelConfig(
            id: "deepseek", name: "DeepSeek", url: "https://api.deepseek.com",
            modelName: "deepseek-v4-flash", temperature: 0.6, provider: .deepseek, role: .premium
        )

        let updated = OnboardingModelConfiguration.applyingLocalServer(
            baseURL: "http://127.0.0.1:8080/v1", kind: .mlxVLM,
            modelID: "nativ-community/SenseNova-Loop-9B-nvfp4", contextWindow: 32_768,
            to: [local, premium]
        )

        #expect(updated.count == 2)
        #expect(updated[1] == premium)
        let entry = updated[0]
        #expect(entry.name == "sensenova-9b")
        #expect(entry.temperature == 0.3)
        #expect(entry.reasoningConfiguration == .requestTokenBudget)
        #expect(entry.url == "http://127.0.0.1:8080/v1")
        #expect(entry.contextWindowTokens == 32_768)
        #expect(entry.supportsVision == true)
        #expect(entry.enabled)
    }

    @Test("A different model renames the entry, and llama-server leaves vision to /props")
    func applyingLocalServerFollowsModelChange() {
        let local = RemoteModelConfig(
            id: "llama", name: "sensenova-9b", url: "http://127.0.0.1:8080/v1",
            modelName: "nativ-community/SenseNova-Loop-9B-nvfp4", temperature: 0.6,
            supportsVision: true
        )

        let updated = OnboardingModelConfiguration.applyingLocalServer(
            baseURL: "http://127.0.0.1:8080/v1", kind: .llamaServer,
            modelID: "/models/Qwen3.6-35B-A3B.gguf", contextWindow: 65_536, to: [local]
        )

        #expect(updated[0].name == "Qwen3.6-35B-A3B")
        #expect(updated[0].modelName == "/models/Qwen3.6-35B-A3B.gguf")
        #expect(updated[0].supportsVision == nil)
    }

    @Test("Effort levels detected on llama-server are dropped for MLX VLM")
    func applyingMLXServerResetsDetectedEffortLevels() {
        let local = RemoteModelConfig(
            id: "llama", name: "sensenova-9b", url: "http://127.0.0.1:8080/v1",
            modelName: "nativ-community/SenseNova-Loop-9B-nvfp4", temperature: 0.6,
            reasoningConfiguration: RemoteReasoningConfiguration(
                mode: .requestEffortLevel, serverEffortLevels: ["low", "medium", "xhigh"]
            )
        )

        let mlx = OnboardingModelConfiguration.applyingLocalServer(
            baseURL: "http://127.0.0.1:8080/v1", kind: .mlxVLM,
            modelID: "nativ-community/SenseNova-Loop-9B-nvfp4", contextWindow: 32_768, to: [local]
        )
        let llama = OnboardingModelConfiguration.applyingLocalServer(
            baseURL: "http://127.0.0.1:8080/v1", kind: .llamaServer,
            modelID: "nativ-community/SenseNova-Loop-9B-nvfp4", contextWindow: 32_768, to: [local]
        )

        #expect(mlx[0].reasoningConfiguration.mode == .serverManaged)
        #expect(mlx[0].reasoningConfiguration.serverEffortLevels == nil)
        #expect(llama[0].reasoningConfiguration == local.reasoningConfiguration)
    }

    @Test("Without a local entry, applying a server appends one")
    func applyingLocalServerAppendsEntry() {
        let updated = OnboardingModelConfiguration.applyingLocalServer(
            baseURL: "http://127.0.0.1:1234/v1", kind: .openAICompatible,
            modelID: "qwen3-coder-30b", contextWindow: 16_384, to: []
        )

        #expect(updated.map(\.id) == ["llama"])
        #expect(updated[0].supportsVision == false)
        #expect(updated[0].contextWindowTokens == 16_384)
    }

    @Test("The sheet prefers llama-server and writes the catalog only on confirmation")
    func onboardingStorePrefersLlamaAndWritesOnConfirm() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-OnboardingStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = TurboCodeConfig(rootURL: home.appendingPathComponent(".turbocode", isDirectory: true))
        try config.performOnboarding(deferModelCatalog: true)

        // LM Studio answers on a lower-priority port than llama-server on 9931,
        // so the preselection must come from the kind, not the scan order.
        let stub = StubHTTPClient(
            responses: [
                "http://127.0.0.1:1234/v1/models": (200, #"{"data":[{"id":"qwen3-coder-30b"}]}"#),
                "http://127.0.0.1:9931/v1/models": (200, modelsListing),
                "http://127.0.0.1:9931/props": (200, #"{"default_generation_settings":{"n_ctx":65536}}"#),
            ],
            postResponse: (200, #"{"choices":[{"message":{"tool_calls":[{"id":"1"}]}}]}"#)
        )
        var completed: [RemoteModelConfig]?
        var dismissed = false
        let store = FirstLaunchOnboardingStore(
            discovery: LocalModelServerDiscovery(http: stub),
            config: config,
            onComplete: { completed = $0 },
            onDismiss: { dismissed = true }
        )

        store.scan()
        for _ in 0..<1_000 where store.isScanning { await Task.yield() }
        #expect(!store.isScanning)
        #expect(store.llamaServers.count == 1)
        #expect(store.otherServers.count == 1)
        #expect(store.selectedServer?.baseURL == "http://127.0.0.1:9931/v1")
        #expect(store.notRunningPorts.count == 4)

        store.showReview()
        #expect(store.displayName == "Qwen3.6-35B-A3B")
        #expect(config.needsModelSetup)

        await store.complete()
        #expect(!config.needsModelSetup)
        #expect(completed?.first(where: { $0.id == "llama" })?.contextWindowTokens == 65_536)
        #expect(!dismissed)
    }

    @Test("Postponing the sheet leaves the catalog missing")
    func postponingWritesNothing() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-OnboardingLater-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = TurboCodeConfig(rootURL: home.appendingPathComponent(".turbocode", isDirectory: true))
        var dismissed = false
        let store = FirstLaunchOnboardingStore(
            discovery: LocalModelServerDiscovery(http: StubHTTPClient()),
            config: config,
            onComplete: { _ in },
            onDismiss: { dismissed = true }
        )

        store.setUpLater()
        #expect(dismissed)
        #expect(config.needsModelSetup)
    }

    @Test("First launch defers models.json until setup completes, and never overwrites it")
    func defersAndWritesModelCatalog() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-ModelSetup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = TurboCodeConfig(rootURL: home.appendingPathComponent(".turbocode", isDirectory: true))

        #expect(config.needsModelSetup)
        try config.performOnboarding(deferModelCatalog: true)
        #expect(config.needsModelSetup)
        #expect(FileManager.default.fileExists(atPath: config.agentTuningConfigurationURL.path))

        var chosen = RemoteModelConfig.fallbackLlama
        chosen.url = "http://192.168.1.120:8080/v1"
        let written = try config.completeModelSetup(localModel: chosen)
        #expect(!config.needsModelSetup)
        #expect(written.first(where: { $0.id == "llama" })?.url == "http://192.168.1.120:8080/v1")
        #expect(written.contains(where: { $0.id == "deepseek" }))

        var other = chosen
        other.url = "http://127.0.0.1:9931/v1"
        let kept = try config.completeModelSetup(localModel: other)
        #expect(kept.first(where: { $0.id == "llama" })?.url == "http://192.168.1.120:8080/v1")
    }
}
