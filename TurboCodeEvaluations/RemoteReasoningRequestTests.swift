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

}
