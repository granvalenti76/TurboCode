import Testing
@testable import TurboCode

@MainActor
@Suite("Agent task invoker factory")
struct AgentTaskInvokerFactoryTests {
    @Test("Delegation stays opt-in while explicit task construction remains available")
    func preservesDelegationBoundary() {
        let factory = AgentTaskInvokerFactory()

        #expect(
            factory.makeDelegateInvoker(
                configuration: nil,
                events: Self.noopEvents
            ) == nil
        )
        #expect(
            factory.makeDelegateInvoker(
                configuration: Self.configuration,
                events: Self.noopEvents
            ) != nil
        )
        _ = factory.makeIndependentTaskInvoker(
            configuration: Self.configuration,
            events: Self.noopEvents
        )
    }

    private static var noopEvents: ModelSessionEvents {
        ModelSessionEvents(
            toolStarted: { _, _, _ in },
            toolFinished: { _, _, _, _ in },
            delegationChanged: { _ in }
        )
    }

    private static var configuration: ModelSessionConfiguration {
        ModelSessionConfiguration(
            backend: .llamaServer,
            activeRemoteModel: .fallbackLlama,
            delegateRemoteModel: .fallbackLlama,
            orchestratorMode: .standalone,
            workspaceRoot: "/tmp/workspace",
            agentTuning: .default,
            availableSkills: [],
            documentationStore: .live,
            activeDynamicProfile: nil,
            reasoningEffort: nil,
            delegateReasoningEffort: nil,
            activeTemperature: nil,
            delegateTemperature: nil,
            delegateToolIDs: nil,
            dropsCompletedToolCalls: false,
            workspaceInstructions: nil
        )
    }
}
