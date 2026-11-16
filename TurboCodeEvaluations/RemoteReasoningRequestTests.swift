import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Remote reasoning requests")
struct RemoteReasoningRequestTests {
    @Test("Server-managed configuration leaves the request without a directive")
    func serverManagedConfigurationOmitsDirective() {
        let configuration = RemoteReasoningConfiguration.serverManaged

        #expect(configuration.requestDirective(for: .low) == nil)
        #expect(configuration.requestDirective(for: .xhigh) == nil)
    }

    @Test("Request budgets map every product level including unlimited maximum")
    func requestBudgetsMapProductLevels() {
        let configuration = RemoteReasoningConfiguration(
            mode: .requestTokenBudget,
            lowTokenBudget: 256,
            mediumTokenBudget: 1_024,
            highTokenBudget: 4_096,
            maximumTokenBudget: nil
        )

        #expect(configuration.requestDirective(for: nil) == .disabled)
        #expect(configuration.requestDirective(for: .low) == .tokenBudget(256))
        #expect(configuration.requestDirective(for: .medium) == .tokenBudget(1_024))
        #expect(configuration.requestDirective(for: .high) == .tokenBudget(4_096))
        #expect(configuration.requestDirective(for: .xhigh) == .tokenBudget(-1))
    }

    @Test("Request adaptation preserves template arguments and adds the selected budget")
    func requestAdaptationMergesTemplateArguments() throws {
        let input: [String: Any] = [
            "model": "configured-model",
            "messages": [["role": "user", "content": "Hello"]],
            "chat_template_kwargs": ["custom_option": "keep"],
        ]
        let data = try JSONSerialization.data(withJSONObject: input)

        let adapted = try RemoteReasoningRequestBody.adapt(
            data,
            directive: .tokenBudget(2_048)
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: adapted) as? [String: Any]
        )
        let templateArguments = try #require(
            object["chat_template_kwargs"] as? [String: Any]
        )

        #expect(templateArguments["custom_option"] as? String == "keep")
        #expect(templateArguments["enable_thinking"] as? Bool == true)
        #expect(object["thinking_budget_tokens"] as? Int == 2_048)
    }

    @Test("Disabled reasoning removes a stale budget")
    func disabledReasoningRemovesBudget() throws {
        let input: [String: Any] = [
            "model": "configured-model",
            "thinking_budget_tokens": 8_192,
        ]
        let data = try JSONSerialization.data(withJSONObject: input)

        let adapted = try RemoteReasoningRequestBody.adapt(data, directive: .disabled)
        let object = try #require(
            JSONSerialization.jsonObject(with: adapted) as? [String: Any]
        )
        let templateArguments = try #require(
            object["chat_template_kwargs"] as? [String: Any]
        )

        #expect(templateArguments["enable_thinking"] as? Bool == false)
        #expect(object["thinking_budget_tokens"] == nil)
    }

    @Test("Legacy model records default to server-managed reasoning")
    func legacyModelConfigurationIsServerManaged() throws {
        let data = Data(
            #"{"id":"local","name":"Local","url":"http://127.0.0.1:8080/v1","modelName":"configured-model"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(RemoteModelConfig.self, from: data)

        #expect(decoded.reasoningConfiguration == .serverManaged)
    }

    @Test("Reasoning configuration persists with the model catalog")
    func reasoningConfigurationPersists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TurboCodeConfig(rootURL: root)
        let model = RemoteModelConfig(
            id: "local",
            name: "Local",
            url: "http://127.0.0.1:8080/v1",
            modelName: "configured-model",
            temperature: 0.6,
            reasoningConfiguration: RemoteReasoningConfiguration(
                mode: .requestTokenBudget,
                lowTokenBudget: 128,
                mediumTokenBudget: 512,
                highTokenBudget: 2_048,
                maximumTokenBudget: 4_096
            )
        )

        try store.saveRemoteModels([model])
        let restored = try #require(store.loadRemoteModels().first)

        #expect(restored.reasoningConfiguration == model.reasoningConfiguration)
    }

    // MARK: - Server-declared effort levels

    private static let effortConfiguration = RemoteReasoningConfiguration(
        mode: .requestEffortLevel,
        serverEffortLevels: ["low", "medium", "xhigh"]
    )

    @Test("Props effort levels are read only when the template declares support")
    func propsEffortLevelsRequireDeclaredSupport() {
        let supported: [String: Any] = [
            "chat_template_caps": [
                "supports_reasoning_effort": true,
                "reasoning_effort_levels": ["low", "medium", "xhigh"],
            ],
        ]
        let unsupported: [String: Any] = [
            "chat_template_caps": [
                "supports_reasoning_effort": false,
                "reasoning_effort_levels": ["low"],
            ],
        ]

        #expect(LlamaServerRuntimeProbe.reasoningEffortLevels(inProps: supported)
            == ["low", "medium", "xhigh"])
        #expect(LlamaServerRuntimeProbe.reasoningEffortLevels(inProps: unsupported) == nil)
        #expect(LlamaServerRuntimeProbe.reasoningEffortLevels(inProps: [:]) == nil)
    }

    @Test("Effort-level mode offers only levels the server declared")
    func effortLevelModeOffersDeclaredLevels() {
        let configuration = Self.effortConfiguration

        #expect(configuration.supportedEfforts == [.low, .medium, .xhigh])
        #expect(configuration.requestDirective(for: .low) == .effortLevel("low"))
        #expect(configuration.requestDirective(for: .xhigh) == .effortLevel("xhigh"))
        #expect(configuration.requestDirective(for: nil) == .disabled)
    }

    @Test("An undeclared stored preference resolves to the nearest lower level")
    func undeclaredPreferenceResolvesToNearestLowerLevel() {
        let configuration = Self.effortConfiguration
        let onlyHigh = RemoteReasoningConfiguration(
            mode: .requestEffortLevel,
            serverEffortLevels: ["xhigh"]
        )

        #expect(configuration.resolvedEffort(.high) == .medium)
        #expect(configuration.requestDirective(for: .high) == .effortLevel("medium"))
        #expect(onlyHigh.resolvedEffort(.low) == .xhigh)
    }

    @Test("Effort-level mode without detected levels sends nothing and fails validation")
    func effortLevelModeWithoutLevelsIsInert() {
        let configuration = RemoteReasoningConfiguration(mode: .requestEffortLevel)

        #expect(configuration.requestDirective(for: .medium) == nil)
        #expect(throws: (any Error).self) { try configuration.validated() }
        #expect((try? Self.effortConfiguration.validated()) != nil)
    }

    @Test("Effort-level adaptation sends reasoning_effort and drops a stale budget")
    func effortLevelAdaptationSendsTemplateArgument() throws {
        let input: [String: Any] = [
            "model": "configured-model",
            "thinking_budget_tokens": 8_192,
            "chat_template_kwargs": ["custom_option": "keep"],
        ]
        let data = try JSONSerialization.data(withJSONObject: input)

        let adapted = try RemoteReasoningRequestBody.adapt(
            data,
            directive: .effortLevel("medium")
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: adapted) as? [String: Any]
        )
        let templateArguments = try #require(
            object["chat_template_kwargs"] as? [String: Any]
        )

        #expect(templateArguments["custom_option"] as? String == "keep")
        #expect(templateArguments["enable_thinking"] as? Bool == true)
        #expect(templateArguments["reasoning_effort"] as? String == "medium")
        #expect(object["thinking_budget_tokens"] == nil)
    }

    @Test("Composer options follow the server-declared levels")
    func composerOptionsFollowServerLevels() {
        let model = RemoteModelConfig(
            id: ProfileBaseModelID.llama.rawValue,
            name: "Local",
            url: "http://127.0.0.1:8080/v1",
            modelName: "configured-model",
            temperature: 0.6,
            reasoningConfiguration: Self.effortConfiguration
        )

        #expect(ComposerProfileMenu.reasoningOptions(for: .llama, models: [model])
            == [.low, .medium, .xhigh])
    }

    @Test("Detected effort levels persist with the model catalog")
    func effortLevelsPersist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TurboCodeConfig(rootURL: root)
        let model = RemoteModelConfig(
            id: "local",
            name: "Local",
            url: "http://127.0.0.1:8080/v1",
            modelName: "configured-model",
            temperature: 0.6,
            reasoningConfiguration: Self.effortConfiguration
        )

        try store.saveRemoteModels([model])
        let restored = try #require(store.loadRemoteModels().first)

        #expect(restored.reasoningConfiguration == Self.effortConfiguration)
    }

    @Test("Off disables server thinking and an explicit level re-enables it")
    func serverReasoningOffIsClearedByLevelSelection() throws {
        let suite = "RemoteReasoningRequestTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = RemoteModelConfig(
            id: ProfileBaseModelID.llama.rawValue,
            name: "Local",
            url: "http://127.0.0.1:8080/v1",
            modelName: "configured-model",
            temperature: 0.6,
            reasoningConfiguration: Self.effortConfiguration
        )
        let store = ModelRuntimeStore(
            models: [model],
            profiles: [],
            preferences: preferences,
            dynamicRoutingAssetsPrepared: false
        )

        store.selectServerReasoningOff(for: .llama)
        #expect(store.reasoningEffort == nil)
        #expect(model.reasoningConfiguration.requestDirective(for: store.reasoningEffort)
            == .disabled)

        store.setReasoningEffort(.low)
        #expect(store.serverReasoningOff == false)
        #expect(store.reasoningEffort == .low)
    }
}
