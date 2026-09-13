import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Composer profile menu")
struct ComposerProfileMenuTests {
    @Test("Each submenu uses its destination's reasoning contract")
    func reasoningBelongsToDestination() {
        var local = localModel()
        var remote = localModel()
        remote = RemoteModelConfig(
            id: "deepseek", name: "Remote", url: remote.url,
            modelName: remote.modelName, temperature: 0.6,
            role: .premium, reasoningTransport: .deepseekThinking
        )
        #expect(ComposerProfileMenu.reasoningOptions(for: .llama, models: [local, remote]).isEmpty)
        #expect(ComposerProfileMenu.reasoningOptions(for: .deepseek, models: [local, remote]) == [.low, .medium, .high])
        local.reasoningConfiguration = budgetConfiguration
        #expect(ComposerProfileMenu.reasoningOptions(for: .llama, models: [local, remote]) == [.low, .medium, .high, .xhigh])
        local.supportsReasoning = false
        #expect(ComposerProfileMenu.reasoningOptions(for: .llama, models: [local]).isEmpty)
        #expect(ComposerProfileMenu.reasoningOptions(for: .onDevice, models: []).contains(.xhigh))
    }

    @Test("Selecting a default exits legacy delegation and applies destination effort")
    func defaultSelectionExitsLegacyMode() throws {
        let domain = "ComposerProfileMenuTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        preferences.set(OrchestratorMode.orchestrator.rawValue, forKey: "orchestratorMode")
        var local = localModel()
        local.reasoningConfiguration = budgetConfiguration
        let store = ModelRuntimeStore(models: [local], profiles: [], preferences: preferences)
        #expect(store.orchestratorMode == .orchestrator)

        #expect(store.selectBuiltInProfile(.llama, reasoning: .xhigh))

        #expect(store.orchestratorMode == .standalone)
        #expect(store.activeBackend == .llamaServer)
        #expect(store.activeDynamicProfileID == nil)
        #expect(store.reasoningEffort == .xhigh)
        #expect(preferences.string(forKey: "orchestratorMode") == OrchestratorMode.standalone.rawValue)
        // Unavailable destinations must not discard the current selection.
        #expect(!store.selectBuiltInProfile(.deepseek, reasoning: .low))
        #expect(store.activeBackend == .llamaServer)
        #expect(store.reasoningEffort == .xhigh)
    }

    @Test("Renaming reloads the catalog and preserves external provider edits")
    func displayNamePreservesProviderConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = TurboCodeConfig(rootURL: root)
        var original = localModel()
        try config.saveRemoteModels([original])
        // Simulate an external endpoint edit after Profiles has read its draft.
        original.url = "http://127.0.0.1:9234/v1"
        original.reasoningConfiguration = budgetConfiguration
        let other = RemoteModelConfig(
            id: "other", name: "Other", url: "http://127.0.0.1:9235/v1",
            modelName: "other-configured-model", temperature: 0.4
        )
        try config.saveRemoteModels([original, other])

        let updated = try config.updateRemoteModelDisplayName("  Local writing model  ", for: "llama")
        var expected = original
        expected.name = "Local writing model"
        #expect(updated == [expected, other])
        #expect(try config.loadRemoteModels() == [expected, other])
        #expect(throws: RemoteModelDisplayNameError.self) {
            try config.updateRemoteModelDisplayName(" \n ", for: "llama")
        }
        #expect(throws: RemoteModelDisplayNameError.self) {
            try config.updateRemoteModelDisplayName("Missing", for: "missing")
        }
        #expect(try config.loadRemoteModels() == [expected, other])
    }

    @Test("Custom selections exit legacy mode and retain their identity during metadata edits")
    func customSelectionKeepsItsIdentity() throws {
        let domain = "ComposerProfileMenuTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        preferences.set(OrchestratorMode.orchestrator.rawValue, forKey: "orchestratorMode")
        let profile = UserDynamicProfile(name: "Writing", baseModelID: .llama)
        let store = ModelRuntimeStore(models: [localModel()], profiles: [profile], preferences: preferences)

        #expect(store.selectDynamicProfile(profile.id))
        #expect(store.orchestratorMode == .standalone)
        store.updateRemoteModelDisplayName(id: "llama", name: "Renamed default")
        #expect(store.composerModel == profile.name)
        #expect(!store.selectBuiltInProfile(.deepseek))
        #expect(store.activeDynamicProfileID == profile.id)
        #expect(store.composerModel == profile.name)
        #expect(store.selectBuiltInProfile(.llama))
        #expect(store.activeDynamicProfileID == nil)
        #expect(store.composerModel == "Renamed default")
    }

    @Test("A label refresh preserves the selected route and reasoning")
    func labelRefreshIsMetadataOnly() throws {
        let domain = "ComposerProfileMenuTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        var local = localModel()
        local.reasoningConfiguration = budgetConfiguration
        let store = ModelRuntimeStore(models: [local], profiles: [], preferences: preferences)
        #expect(store.selectBuiltInProfile(.llama, reasoning: .high))
        store.updateRemoteModelDisplayName(id: "llama", name: "Local alias")
        #expect(store.composerModel == "Local alias")
        #expect(store.activeRemoteModelID == "llama")
        #expect(store.reasoningEffort == .high)
        #expect(store.remoteModels.first?.url == local.url)
        #expect(store.remoteModels.first?.modelName == local.modelName)
        #expect(ComposerProfileMenu.name(for: .llama, models: store.remoteModels) == "Local alias")
        #expect(store.selectBuiltInProfile(.onDevice))
        let previousLabel = store.composerModel
        store.updateRemoteModelDisplayName(id: "llama", name: "Another alias")
        #expect(store.composerModel == previousLabel)
        #expect(store.activeBackend == .foundationApple)
    }

    @Test("Editing the Codex default preserves an active custom model")
    func codexDefaultDoesNotReplaceCustomModel() throws {
        let domain = "ComposerProfileMenuTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: domain))
        defer { preferences.removePersistentDomain(forName: domain) }
        let current = descriptor(id: "custom", efforts: [.medium, .high], defaultEffort: .medium)
        let chosen = descriptor(id: "direct", efforts: [.low], defaultEffort: .low)
        let store = CodexRuntimeStore(preferences: preferences)
        store.models = [current, chosen]
        store.model = current

        store.configureDefaultModel(id: chosen.id, updateActiveModel: false)

        #expect(store.model == current)
        #expect(store.preferredModel == chosen)
        #expect(store.reasoningEffort == .low)
        #expect(store.connectionState == .idle)
        #expect(preferences.string(forKey: "codexModelID") == chosen.id)
        store.configureDefaultModel(id: "unavailable", updateActiveModel: true)
        #expect(store.model == current)
        #expect(store.preferredModel == chosen)
        store.configureDefaultModel(id: chosen.id, updateActiveModel: true)
        #expect(store.model == chosen)
    }

    private var budgetConfiguration: RemoteReasoningConfiguration {
        RemoteReasoningConfiguration(
            mode: .requestTokenBudget, lowTokenBudget: 128,
            mediumTokenBudget: 512, highTokenBudget: 2_048, maximumTokenBudget: 4_096
        )
    }

    private func localModel() -> RemoteModelConfig {
        RemoteModelConfig(
            id: "llama", name: "Local", url: "http://127.0.0.1:9233/v1",
            modelName: "configured-local-model", temperature: 0.6
        )
    }

    private func descriptor(
        id: String, efforts: [CodexReasoningEffort], defaultEffort: CodexReasoningEffort
    ) -> CodexModelDescriptor {
        CodexModelDescriptor(
            id: id, model: id, displayName: "Test model", description: "",
            supportedReasoningEfforts: efforts.map { CodexReasoningOption(reasoningEffort: $0, description: "") },
            defaultReasoningEffort: defaultEffort
        )
    }
}
