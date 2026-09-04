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

    @Test("Remote delegate prompt leaves reasoning control to its transport")
    func remoteDelegatePromptOmitsReasoningPolicy() {
        let factory = AgentTaskInvokerFactory()
        let workerEffort = factory.makeIndependentTaskInvoker(
            configuration: Self.makeConfiguration(
                reasoningEffort: nil,
                delegateReasoningEffort: .xhigh
            ),
            events: Self.noopEvents
        )
        let coordinatorEffort = factory.makeIndependentTaskInvoker(
            configuration: Self.makeConfiguration(
                reasoningEffort: .xhigh,
                delegateReasoningEffort: nil
            ),
            events: Self.noopEvents
        )

        #expect(!workerEffort.context.instructions.contains("Reasoning policy ("))
        #expect(
            !coordinatorEffort.context.instructions.contains(
                "Reasoning policy ("
            )
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
        makeConfiguration()
    }

    private static func makeConfiguration(
        reasoningEffort: ReasoningEffort? = nil,
        delegateReasoningEffort: ReasoningEffort? = nil
    ) -> ModelSessionConfiguration {
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
            reasoningEffort: reasoningEffort,
            delegateReasoningEffort: delegateReasoningEffort,
            activeTemperature: nil,
            delegateTemperature: nil,
            delegateToolIDs: nil,
            dropsCompletedToolCalls: false,
            workspaceInstructions: nil
        )
    }
}
