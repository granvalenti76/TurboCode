import Foundation
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
    func remoteDelegatePromptOmitsReasoningPolicy() throws {
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

        let worker = try #require(workerEffort as? ConfiguredAgentTaskInvoker)
        let coordinator = try #require(
            coordinatorEffort as? ConfiguredAgentTaskInvoker
        )
        #expect(!worker.context.instructions.contains("Reasoning policy ("))
        #expect(
            !coordinator.context.instructions.contains(
                "Reasoning policy ("
            )
        )
    }

    @Test("Mixed worker profiles build native and remote pool slots")
    func buildsMixedWorkerPool() throws {
        let workers = [
            ModelWorkerConfiguration(
                id: UUID(),
                name: "Private Scout",
                modelID: .onDevice,
                remoteModel: nil,
                toolIDs: [],
                reasoningEffort: .high,
                temperature: nil
            ),
            ModelWorkerConfiguration(
                id: UUID(),
                name: "Llama Builder",
                modelID: .llama,
                remoteModel: .fallbackLlama,
                toolIDs: [.readFile],
                reasoningEffort: .medium,
                temperature: 0.25
            )
        ]
        let invoker = ModelSessionFactory.makeDelegateInvoker(
            configuration: Self.makeConfiguration(delegateWorkers: workers),
            events: Self.noopEvents
        )
        let pool = try #require(invoker as? ConfiguredAgentTaskPoolInvoker)

        #expect(pool.maximumConcurrentTasks == 2)
        #expect(pool.invokers[0].worker?.role == .microtaskOnDevice)
        #expect(pool.invokers[0].context.temperature == nil)
        // The system model remains the authority: unsupported reasoning
        // requests are removed rather than leaking a remote worker policy.
        #expect(pool.invokers[0].context.reasoningLevel == nil)
        #expect(pool.invokers[1].worker?.modelName == "Llama Builder")
        #expect(pool.invokers[1].context.temperature == 0.25)
        #expect(pool.invokers[1].context.reasoningLevel == .moderate)
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
        delegateReasoningEffort: ReasoningEffort? = nil,
        delegateWorkers: [ModelWorkerConfiguration] = []
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
            delegateWorkers: delegateWorkers,
            dropsCompletedToolCalls: false,
            workspaceInstructions: nil
        )
    }
}
