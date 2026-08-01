import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Agent Activity runtime integration")
struct AgentActivityRuntimeIntegrationTests {
    @Test("Configured invocation drives one complete Activity lifecycle")
    func configuredInvocationDrivesActivity() async throws {
        let store = AgentActivityStore()
        let envelope = try makeEnvelope()
        let runner = ActivityTestRunner(
            outcome: .completed,
            finishesTool: true
        )
        let invoker = makeInvoker(runner: runner, store: store)

        let result = await invoker.invoke(envelope)

        #expect(result.outcome == .completed)
        #expect(store.current?.taskID == envelope.taskID)
        #expect(store.current?.attemptID == envelope.attemptID)
        #expect(store.current?.coordinator.modelName == "DeepSeek Coordinator")
        #expect(store.current?.worker.modelName == "Local Worker")
        #expect(store.current?.phase == .succeeded)
        #expect(store.current?.activeTool == nil)
        #expect(store.current?.finalResult == result)
    }

    @Test("Terminal runner result closes a tool without an output callback")
    func terminalResultClosesOpenTool() async throws {
        let store = AgentActivityStore()
        let envelope = try makeEnvelope(attemptID: "attempt-failure")
        let runner = ActivityTestRunner(
            outcome: .failed,
            finishesTool: false
        )
        let invoker = makeInvoker(runner: runner, store: store)

        let result = await invoker.invoke(envelope)

        #expect(result.outcome == .failed)
        #expect(store.current?.phase == .failed)
        #expect(store.current?.activeTool == nil)
        #expect(store.current?.finalResult == result)
    }

    @Test("Cancelling a suspended worker closes Activity and its active tool")
    func cancellationClosesSuspendedActivity() async throws {
        let store = AgentActivityStore()
        let envelope = try makeEnvelope(attemptID: "attempt-cancelled")
        let invoker = makeInvoker(
            runner: SuspendedActivityRunner(),
            store: store
        )
        let task = Task { @MainActor in
            await invoker.invoke(envelope)
        }

        // The fake publishes a tool before suspending, reproducing Stop during
        // real worker execution rather than cancellation before handoff.
        while store.current?.activeTool == nil {
            await Task.yield()
        }
        task.cancel()
        let result = await task.value

        #expect(result.outcome == .cancelled)
        #expect(result.failureReason == .cancelled)
        #expect(store.current?.phase == .cancelled)
        #expect(store.current?.activeTool == nil)
        #expect(store.current?.finalResult == result)
    }

    @Test("Foundation Models and Codex tool calls share the Activity shape")
    func providerToolCallsShareMapping() {
        let foundationCall = Transcript.ToolCall(
            id: "shared-call",
            toolName: "read_file",
            arguments: GeneratedContent(
                properties: ["filePath": "TurboCode/App.swift"]
            )
        )
        let codexCall = CodexDynamicToolCall(
            rpcID: .integer(1),
            callID: "shared-call",
            tool: "read_file",
            arguments: .object(["filePath": .string("TurboCode/App.swift")])
        )

        let foundationTool = AgentActivityRuntimeMapping.tool(
            from: foundationCall,
            owner: .worker
        )
        let codexTool = AgentActivityRuntimeMapping.tool(
            from: codexCall,
            owner: .worker
        )

        #expect(foundationTool == codexTool)
        #expect(foundationTool.owner == .worker)
    }

    @Test("Coordinator and worker ownership remains explicit")
    func preservesToolOwner() {
        let call = Transcript.ToolCall(
            id: "route-call",
            toolName: "xcode_project",
            arguments: GeneratedContent(properties: [:])
        )

        let coordinatorTool = AgentActivityRuntimeMapping.tool(
            from: call,
            owner: .coordinator
        )
        let workerTool = AgentActivityRuntimeMapping.tool(
            from: call,
            owner: .worker
        )

        #expect(coordinatorTool.owner == .coordinator)
        #expect(workerTool.owner == .worker)
        #expect(coordinatorTool != workerTool)
    }

    private func makeInvoker(
        runner: any AgentTaskRunning,
        store: AgentActivityStore
    ) -> ConfiguredAgentTaskInvoker {
        let events = AgentTaskRunnerEvents(
            toolStarted: { event in
                await store.apply(
                    .toolStarted(
                        taskID: event.taskID,
                        attemptID: event.attemptID,
                        tool: AgentActivityRuntimeMapping.tool(
                            from: event.call,
                            owner: .worker
                        )
                    )
                )
            },
            toolFinished: { event in
                await store.apply(
                    .toolFinished(
                        taskID: event.taskID,
                        attemptID: event.attemptID,
                        callID: event.call.id
                    )
                )
            }
        )
        return ConfiguredAgentTaskInvoker(
            runner: runner,
            context: AgentTaskRunContext(
                model: SystemLanguageModel.default,
                toolPlan: ModelToolPlan(
                    profile: .delegate,
                    tier: .standard,
                    assignments: []
                ),
                tools: [],
                instructions: "Test worker.",
                temperature: nil,
                reasoningLevel: nil
            ),
            events: events,
            coordinator: .init(
                modelName: "DeepSeek Coordinator",
                role: .powerfulCoordinator
            ),
            worker: .init(
                modelName: "Local Worker",
                role: .codingWorker
            ),
            activityChanged: { event in
                await store.apply(event)
            }
        )
    }

    private func makeEnvelope(
        attemptID: String = "attempt-runtime"
    ) throws -> AgentTaskEnvelope {
        try AgentTaskEnvelope(
            taskID: "task-runtime",
            attemptID: attemptID,
            goal: "Exercise Activity event wiring.",
            acceptanceCriteria: ["Activity reaches the matching terminal state."],
            allowedTools: [.readFile]
        )
    }
}

private nonisolated struct SuspendedActivityRunner: AgentTaskRunning {
    @MainActor
    func run(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async -> AgentTaskResult {
        let call = Transcript.ToolCall(
            id: "suspended-worker-tool",
            toolName: "read_file",
            arguments: GeneratedContent(
                properties: ["filePath": "TurboCode/App.swift"]
            )
        )
        await events.toolStarted(
            AgentTaskToolCallEvent(
                taskID: envelope.taskID,
                attemptID: envelope.attemptID,
                call: call
            )
        )
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            // The typed terminal result is the runner boundary consumed by
            // Activity; no tool-finished callback is intentionally emitted.
        }
        return try! AgentTaskResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            outcome: .cancelled,
            technicalSummary: "The suspended worker was cancelled.",
            failureReason: .cancelled
        )
    }
}

private nonisolated struct ActivityTestRunner: AgentTaskRunning {
    let outcome: AgentTaskOutcome
    let finishesTool: Bool

    @MainActor
    func run(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async -> AgentTaskResult {
        let call = Transcript.ToolCall(
            id: "worker-tool",
            toolName: "read_file",
            arguments: GeneratedContent(
                properties: ["filePath": "TurboCode/App.swift"]
            )
        )
        await events.toolStarted(
            AgentTaskToolCallEvent(
                taskID: envelope.taskID,
                attemptID: envelope.attemptID,
                call: call
            )
        )
        if finishesTool {
            await events.toolFinished(
                AgentTaskToolOutputEvent(
                    taskID: envelope.taskID,
                    attemptID: envelope.attemptID,
                    call: call,
                    output: Transcript.ToolOutput(
                        id: call.id,
                        toolName: call.toolName,
                        segments: [
                            .text(Transcript.TextSegment(content: "Read complete."))
                        ]
                    )
                )
            )
        }

        return (try? AgentTaskResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            outcome: outcome,
            technicalSummary: "Runtime integration result.",
            failureReason: outcome == .failed ? .workerFailed : nil
        )) ?? .invalidContractResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID
        )
    }
}
