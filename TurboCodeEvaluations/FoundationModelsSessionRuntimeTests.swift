import Foundation
import FoundationModels
import FoundationModelsUtilities
import Testing
@testable import TurboCode

@MainActor
@Suite("Foundation Models session runtime ownership")
struct FoundationModelsSessionRuntimeTests {
    @Test("Runtime scopes the reasoning relay to Llama")
    func reasoningRelayIsProviderScoped() async throws {
        let runtime = FoundationModelsSessionRuntime(
            backend: .llamaServer
        ) { _ in
            SystemLanguageModel.default
        }

        let llamaRelay = await runtime.resources(for: .llamaServer).reasoningRelay
        #expect(llamaRelay != nil)
        #expect(
            await runtime.resources(for: .foundationApple).reasoningRelay == nil
        )
    }

    @Test("Rebuild replaces the session and relay as one runtime unit")
    func rebuildReplacesProviderObjectsTogether() async throws {
        let runtime = FoundationModelsSessionRuntime(
            backend: .llamaServer,
            modelBuilder: { _ in SystemLanguageModel.default }
        )
        let firstResources = await runtime.resources(for: .llamaServer)
        let firstSession = firstResources.session
        let firstRelay = try #require(
            firstResources.reasoningRelay
        )
        await runtime.rebuild(
            configuration: Self.onDeviceConfiguration(),
            history: [],
            events: Self.noopEvents
        )

        let secondResources = await runtime.resources(for: .llamaServer)
        let secondRelay = try #require(secondResources.reasoningRelay)
        #expect(secondResources.session !== firstSession)
        #expect(secondRelay !== firstRelay)
    }

    private static var noopEvents: ModelSessionEvents {
        ModelSessionEvents(
            toolStarted: { _, _, _ in },
            toolFinished: { _, _, _, _ in },
            delegationChanged: { _ in }
        )
    }

    private static func onDeviceConfiguration() -> ModelSessionConfiguration {
        ModelSessionConfiguration(
            backend: .foundationApple,
            activeRemoteModel: nil,
            delegateRemoteModel: .fallbackLlama,
            orchestratorMode: .standalone,
            workspaceRoot: FileManager.default.temporaryDirectory.path,
            agentTuning: .default,
            availableSkills: [],
            documentationStore: .live,
            activeDynamicProfile: nil,
            reasoningEffort: nil,
            delegateReasoningEffort: nil,
            activeTemperature: nil,
            delegateTemperature: nil,
            delegateToolIDs: nil,
            dropsCompletedToolCalls: true,
            workspaceInstructions: nil
        )
    }
}
