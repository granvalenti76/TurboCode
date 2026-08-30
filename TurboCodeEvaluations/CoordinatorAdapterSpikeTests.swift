import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Coordinator adapter spikes")
struct CoordinatorAdapterSpikeTests {
    @Test("DeepSeek custom profiles expose only explicitly selected delegation")
    func deepSeekProfileSelectsStructuredDelegation() {
        let profile = UserDynamicProfile(
            name: "DeepSeek Coordinator",
            baseModelID: .deepseek,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let plan = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .standard,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: false,
                hasDelegateModel: true,
                repositoryMapDetail: nil
            ),
            selectedIDs: profile.resolvedToolIDs
        )

        // Custom profiles are explicit capability boundaries. Built-in
        // profiles may receive create_skill automatically, but this profile
        // selected only the structured delegation capability.
        #expect(plan.registeredIDs == [.delegateTask])
        #expect(ModelToolCatalog.descriptor(for: .delegateTask).name == "Delegate Task")
    }

    @Test("Foundation Models adapter returns a correlated JSON result")
    func foundationModelsAdapterReturnsStructuredResult() async throws {
        let invoker = RecordingTaskInvoker()
        let tool = DelegateTaskTool(invoker: invoker)

        let json = try await tool.call(arguments: makeArguments())
        let result = try JSONDecoder().decode(
            AgentTaskResult.self,
            from: Data(json.utf8)
        )

        #expect(result.taskID == invoker.lastEnvelope?.taskID)
        #expect(result.attemptID == invoker.lastEnvelope?.attemptID)
        #expect(result.outcome == .completed)
        #expect(invoker.lastEnvelope?.mode == .coding)
        #expect(invoker.lastEnvelope?.suggestedScope.isEmpty == true)
        #expect(
            invoker.lastEnvelope?.verificationRequest
                == VerificationRequest.none
        )
    }

    @Test("Shared invocation propagates worker events and cancellation")
    func sharedInvocationPropagatesEventsAndCancellation() async throws {
        let recorder = AgentTaskEventRecorder()
        let eventWorker = SpikeTaskWorker(behavior: .emitEvent)
        let invoker = ConfiguredAgentTaskInvoker(
            runner: BoundedAgentTaskRunner(worker: eventWorker),
            context: makeContext(),
            events: AgentTaskRunnerEvents(
                toolStarted: { event in await recorder.recordStart(event) },
                toolFinished: { event in await recorder.recordFinish(event) }
            )
        )

        let runtimeEnvelope = try makeRuntimeEnvelope()
        let completed = await invoker.invoke(runtimeEnvelope)
        #expect(completed.outcome == .completed)
        #expect(await recorder.identifiers == [
            "start:task-spike-runtime:attempt-spike-runtime",
            "finish:task-spike-runtime:attempt-spike-runtime"
        ])

        let suspendedInvoker = ConfiguredAgentTaskInvoker(
            runner: BoundedAgentTaskRunner(
                worker: SpikeTaskWorker(behavior: .suspend)
            ),
            context: makeContext(),
            events: .none
        )
        let task = Task { @MainActor in
            await suspendedInvoker.invoke(runtimeEnvelope)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        #expect(await task.value.outcome == .cancelled)
    }

    @Test("Codex coordinator exposes the profile-scoped tool and shared result contract")
    func codexBridgeUsesSharedContract() async throws {
        let defaultNames = CodexTurboCodeToolBridge.specifications(
            workspaceRoot: "/workspace",
            agentTuning: .default
        ).map(\.name)
        let coordinatorSpecs = CodexTurboCodeToolBridge.specifications(
            workspaceRoot: "/workspace",
            agentTuning: .default,
            includesDelegation: true
        )
        let delegationSpec = try #require(
            coordinatorSpecs.first(where: { $0.name == "delegate_task" })
        )
        let call = CodexDynamicToolCall(
            rpcID: .integer(73),
            callID: "call-delegate",
            tool: "delegate_task",
            arguments: codexArguments()
        )

        let invoker = RecordingTaskInvoker()
        let execution = try await CodexTurboCodeToolBridge.execute(
            call,
            workspaceRoot: "/workspace",
            workspaceName: "Fixture",
            agentTuning: .default,
            delegationInvoker: invoker
        )
        let result = try JSONDecoder().decode(
            AgentTaskResult.self,
            from: Data(execution.result.text.utf8)
        )

        #expect(!defaultNames.contains("delegate_task"))
        #expect(delegationSpec.inputSchema["required"]?.arrayValue?.count == 2)
        #expect(execution.result.succeeded)
        #expect(result.taskID == invoker.lastEnvelope?.taskID)
        #expect(result.attemptID == invoker.lastEnvelope?.attemptID)
        #expect(invoker.lastEnvelope?.verificationParameters == nil)
    }

    private func makeArguments() -> DelegateTaskArguments {
        DelegateTaskArguments(
            mode: "coding",
            goal: "Inspect one Swift file and return a focused technical result."
        )
    }

    private func makeRuntimeEnvelope() throws -> AgentTaskEnvelope {
        // This spike isolates shared event and cancellation wiring. Requesting
        // verification here would require a verifier and change the expected
        // terminal outcome independently from the behavior under test.
        try AgentTaskEnvelope(
            taskID: "task-spike-runtime",
            attemptID: "attempt-spike-runtime",
            goal: "Inspect one Swift file.",
            acceptanceCriteria: ["Return a focused technical result."],
            suggestedScope: ["TurboCode/App.swift"],
            verificationRequest: .none,
            budget: DelegationBudget(
                timeoutSeconds: 5,
                maximumToolCalls: 2
            )
        )
    }

    private func makeContext() -> AgentTaskRunContext {
        AgentTaskRunContext(
            model: SystemLanguageModel.default,
            tools: [],
            workspaceRoot: "/workspace",
            instructions: "Complete the bounded worker task.",
            temperature: nil,
            reasoningLevel: nil
        )
    }

    private func codexArguments() -> CodexJSONValue {
        .object([
            "mode": .string("coding"),
            "goal": .string("Inspect one Swift file and return a focused technical result.")
        ])
    }
}

@MainActor
private final class RecordingTaskInvoker: AgentTaskInvoking {
    private(set) var lastEnvelope: AgentTaskEnvelope?

    func invoke(_ envelope: AgentTaskEnvelope) async -> AgentTaskResult {
        lastEnvelope = envelope
        return (try? AgentTaskResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            outcome: .completed,
            technicalSummary: "Worker completed the spike task."
        )) ?? .invalidContractResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID
        )
    }
}

private struct SpikeTaskWorker: AgentTaskWorkerExecuting {
    enum Behavior: Sendable {
        case emitEvent
        case suspend
    }

    let behavior: Behavior

    @MainActor
    func execute(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String {
        switch behavior {
        case .emitEvent:
            let call = Transcript.ToolCall(
                id: "worker-call",
                toolName: "read_file",
                arguments: GeneratedContent(properties: ["filePath": "TurboCode/App.swift"])
            )
            await events.toolStarted(
                AgentTaskToolCallEvent(
                    taskID: envelope.taskID,
                    attemptID: envelope.attemptID,
                    call: call
                )
            )
            await events.toolFinished(
                AgentTaskToolOutputEvent(
                    taskID: envelope.taskID,
                    attemptID: envelope.attemptID,
                    call: call,
                    output: Transcript.ToolOutput(
                        id: call.id,
                        toolName: call.toolName,
                        segments: [
                            .text(Transcript.TextSegment(content: "struct App {}"))
                        ]
                    )
                )
            )
            return "Worker event propagation completed."
        case .suspend:
            try await Task.sleep(for: .seconds(60))
            return "Unexpected completion."
        }
    }
}

private actor AgentTaskEventRecorder {
    private(set) var identifiers: [String] = []

    func recordStart(_ event: AgentTaskToolCallEvent) {
        identifiers.append("start:\(event.taskID):\(event.attemptID)")
    }

    func recordFinish(_ event: AgentTaskToolOutputEvent) {
        identifiers.append("finish:\(event.taskID):\(event.attemptID)")
    }
}
