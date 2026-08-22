import Foundation
import FoundationModels
import FoundationModelsUtilities
import Testing
@testable import TurboCode

@MainActor
@Suite("Foundation Models session runtime ownership")
struct FoundationModelsSessionRuntimeTests {
    @Test("Runtime scopes the reasoning relay to Llama")
    func reasoningRelayIsProviderScoped() throws {
        var constructedRelay: ReasoningStreamRelay?
        let runtime = FoundationModelsSessionRuntime(
            backend: .llamaServer
        ) { relay in
            constructedRelay = relay
            return SystemLanguageModel.default
        }

        let llamaRelay = try #require(
            runtime.activeReasoningStreamRelay(for: .llamaServer)
        )
        #expect(constructedRelay === llamaRelay)
        #expect(
            runtime.activeReasoningStreamRelay(for: .foundationApple) == nil
        )
    }

    @Test("Rebuild replaces the session and relay as one runtime unit")
    func rebuildReplacesProviderObjectsTogether() throws {
        let runtime = FoundationModelsSessionRuntime(
            backend: .llamaServer,
            modelBuilder: { _ in SystemLanguageModel.default }
        )
        let firstSession = runtime.session
        let firstRelay = try #require(
            runtime.activeReasoningStreamRelay(for: .llamaServer)
        )
        runtime.rebuild(
            configuration: Self.onDeviceConfiguration(),
            history: [],
            events: Self.noopEvents
        )

        let secondRelay = try #require(
            runtime.activeReasoningStreamRelay(for: .llamaServer)
        )
        #expect(runtime.session !== firstSession)
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
