import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Coordinator adapter spikes")
struct CoordinatorAdapterSpikeTests {
    @Test("DeepSeek dynamic profiles can select only structured delegation")
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

        #expect(result.taskID == "task-spike")
        #expect(result.attemptID == "attempt-spike")
        #expect(result.outcome == .completed)
        #expect(invoker.lastEnvelope?.allowedTools == [.readFile])
        #expect(invoker.lastEnvelope?.verificationRequest == .test)
        #expect(invoker.lastEnvelope?.verificationParameters?.scheme == "FixtureTests")
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

        let completed = await invoker.invoke(try makeArguments().envelope())
        #expect(completed.outcome == .completed)
        #expect(await recorder.identifiers == [
            "start:task-spike:attempt-spike",
            "finish:task-spike:attempt-spike"
        ])

        let suspendedInvoker = ConfiguredAgentTaskInvoker(
            runner: BoundedAgentTaskRunner(
                worker: SpikeTaskWorker(behavior: .suspend)
            ),
            context: makeContext(),
            events: .none
        )
        let cancellationEnvelope = try makeArguments().envelope()
        let task = Task { @MainActor in
            await suspendedInvoker.invoke(cancellationEnvelope)
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        #expect(await task.value.outcome == .cancelled)
    }

    @Test("Codex bridge exposes the same opt-in tool and result contract")
    func codexBridgeUsesSharedContract() async throws {
        let defaultNames = CodexTurboCodeToolBridge.specifications(
            workspaceRoot: "/workspace",
            agentTuning: .default
        ).map(\.name)
        let spikeSpecs = CodexTurboCodeToolBridge.specifications(
            workspaceRoot: "/workspace",
            agentTuning: .default,
            includesDelegation: true
        )
        let delegationSpec = try #require(
            spikeSpecs.first(where: { $0.name == "delegate_task" })
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
        #expect(delegationSpec.inputSchema["required"]?.arrayValue?.count == 9)
        #expect(execution.result.succeeded)
        #expect(result.taskID == "task-spike")
        #expect(result.attemptID == "attempt-spike")
        #expect(invoker.lastEnvelope?.verificationParameters?.destination == "platform=macOS")
    }

    private func makeArguments() -> DelegateTaskArguments {
        DelegateTaskArguments(
            taskID: "task-spike",
            attemptID: "attempt-spike",
            goal: "Inspect one Swift file.",
            acceptanceCriteria: ["Return a focused technical result."],
            suggestedScope: ["TurboCode/App.swift"],
            allowedTools: [ToolCapabilityID.readFile.rawValue],
            verificationRequest: VerificationRequest.test.rawValue,
            verificationContainerPath: "Fixture.xcodeproj",
            verificationScheme: "FixtureTests",
            verificationConfiguration: "Debug",
            verificationDestination: "platform=macOS",
            timeoutSeconds: 5,
            maximumToolCalls: 2
        )
    }

    private func makeContext() -> AgentTaskRunContext {
        AgentTaskRunContext(
            model: SystemLanguageModel.default,
            toolPlan: ModelToolPlan(
                profile: .delegate,
                tier: .standard,
                assignments: [
                    .init(id: .readFile, isRegistered: true, unavailableReason: nil)
                ]
            ),
            tools: [],
            workspaceRoot: "/workspace",
            instructions: "Complete the bounded worker task.",
            temperature: nil,
            reasoningLevel: nil
        )
    }

    private func codexArguments() -> CodexJSONValue {
        .object([
            "taskID": .string("task-spike"),
            "attemptID": .string("attempt-spike"),
            "goal": .string("Inspect one Swift file."),
            "acceptanceCriteria": .array([
                .string("Return a focused technical result.")
            ]),
            "suggestedScope": .array([.string("TurboCode/App.swift")]),
            "allowedTools": .array([.string("read_file")]),
            "verificationRequest": .string("test"),
            "verificationContainerPath": .string("Fixture.xcodeproj"),
            "verificationScheme": .string("FixtureTests"),
            "verificationConfiguration": .string("Debug"),
            "verificationDestination": .string("platform=macOS"),
            "timeoutSeconds": .integer(5),
            "maximumToolCalls": .integer(2)
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
