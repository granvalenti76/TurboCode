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

    @Test("Turn-aware invocation carries parent ownership into the worker envelope")
    func turnAwareInvocationCarriesParentOwnership() async throws {
        let recorder = ParentTurnRecorder()
        let invoker = ConfiguredAgentTaskInvoker(
            runner: ParentTurnRecordingRunner(recorder: recorder),
            context: AgentTaskRunContext(
                model: SystemLanguageModel.default,
                tools: [],
                instructions: "Test worker.",
                temperature: nil,
                reasoningLevel: nil
            ),
            events: .none
        )
        let parent = TurnID(rawValue: "parent-turn")

        _ = await invoker.invoke(
            try makeEnvelope(),
            parentTurnID: parent
        )

        #expect(await recorder.value == parent)
    }

    @Test("Native backend adapter normalizes lifecycle and terminal output")
    func nativeBackendAdapterNormalizesLifecycle() async {
        let turnID = TurnID(rawValue: "native-adapter-turn")
        let adapter = NativeBackendSession(
            backend: .foundationApple,
            runner: AdapterNativeRunner(
                outcome: .completed(
                    content: "Native result.",
                    reasoning: "Native reasoning."
                )
            ),
            session: LanguageModelSession(model: SystemLanguageModel.default),
            mode: .standalone,
            workspaceKind: "test"
        )
        let capture = RuntimeEventCapture()
        let result = await adapter.run(
            request: TurnRequest(
                id: turnID,
                prompt: "Run adapter test.",
                backend: .foundationApple,
                modelName: "Test model",
                workspaceRoot: "/tmp"
            ),
            events: BackendSessionEvents { event in
                await capture.append(event)
            }
        )
        let received = await capture.events

        #expect(result.assistantText == "Native result.")
        #expect(result.reasoningText == "Native reasoning.")
        #expect(result.outcome == .succeeded)
        #expect(received.count == 3)
        #expect(received.allSatisfy { $0.turnID == turnID })
        let lifecycle = received.map { event -> String in
            switch event {
            case .started: "started"
            case .phaseChanged(_, .streaming, _): "streaming"
            case .completed: "completed"
            default: "unexpected"
            }
        }
        // Awaited emission provides backpressure across actors: terminal state
        // cannot overtake admission or the first streaming transition.
        #expect(lifecycle == ["started", "streaming", "completed"])
    }

    @Test("Native adapter preserves lifecycle for Apple, Llama, and DeepSeek")
    func nativeBackendAdapterCoversProviderMatrix() async {
        // These doubles exercise the harness boundary without requiring a live
        // Llama endpoint or DeepSeek credentials. Transport-specific
        // behavior remains covered by the provider runner tests.
        let backends: [ModelBackend] = [
            .foundationApple,
            .llamaServer,
            .premium
        ]

        for backend in backends {
            let turnID = TurnID(rawValue: "native-matrix-\(backend.rawValue)")
            let adapter = NativeBackendSession(
                backend: backend,
                runner: AdapterNativeRunner(
                    outcome: .completed(
                        content: "Result for \(backend.rawValue).",
                        reasoning: "Reasoning for \(backend.rawValue)."
                    )
                ),
                session: LanguageModelSession(model: SystemLanguageModel.default),
                mode: .standalone,
                workspaceKind: backend.rawValue
            )
            let capture = RuntimeEventCapture()
            let result = await adapter.run(
                request: TurnRequest(
                    id: turnID,
                    prompt: "Run provider matrix test.",
                    backend: backend,
                    modelName: "Test \(backend.rawValue)",
                    workspaceRoot: "/tmp"
                ),
                events: BackendSessionEvents { event in
                    await capture.append(event)
                }
            )
            let received = await capture.events

            #expect(result.assistantText == "Result for \(backend.rawValue).")
            #expect(result.reasoningText == "Reasoning for \(backend.rawValue).")
            #expect(result.outcome == .succeeded)
            #expect(received.count == 3)
            #expect(received.allSatisfy { $0.turnID == turnID })
        }
    }

    @Test("Codex backend adapter normalizes streamed output and tool results")
    func codexBackendAdapterNormalizesLifecycle() async {
        let turnID = TurnID(rawValue: "codex-adapter-turn")
        let listing = WorkspaceListingBlock(
            toolCallID: "codex-tool",
            path: ".",
            entries: [],
            totalCount: 0,
            isTruncated: false,
            errorMessage: nil
        )
        let adapter = CodexBackendSession(
            runtime: AdapterCodexRuntime(
                receipt: .workspaceListing(listing)
            ),
            turboThreadID: "thread-test",
            agentTuning: AgentTuningConfig()
        )
        let capture = RuntimeEventCapture()
        let result = await adapter.run(
            request: TurnRequest(
                id: turnID,
                prompt: "Run Codex adapter test.",
                backend: .codex,
                modelName: "Codex test model",
                workspaceRoot: "/tmp"
            ),
            events: BackendSessionEvents { event in
                await capture.append(event)
            }
        )
        let received = await capture.events

        #expect(result.assistantText == "Codex result.")
        #expect(result.reasoningText == "Codex reasoning.")
        #expect(result.outcome == .succeeded)
        // Tool events are themselves lifecycle transitions. The adapter must
        // not also emit toolExecuting/streaming phase duplicates, because the
        // runtime owns that reduction and presentation consumes the payload.
        #expect(received.count == 7)
        #expect(received.allSatisfy { $0.turnID == turnID })
        let phases = received.compactMap { event -> TurnPhase? in
            guard case .phaseChanged(_, let phase, _) = event else {
                return nil
            }
            return phase
        }
        #expect(phases == [.streaming])
        let toolResults = received.compactMap { event -> ToolResult? in
            guard case .toolFinished(let toolResult) = event else {
                return nil
            }
            return toolResult
        }
        #expect(toolResults.count == 1)
        if let toolResult = toolResults.first {
            #expect(toolResult.status == .succeeded)
            #expect(toolResult.durationMilliseconds != nil)
            #expect(toolResult.receipt == .workspaceListing(listing))
        }
    }

    @Test("Codex backend adapter preserves failed tool results")
    func codexBackendAdapterPreservesFailedToolResults() async {
        let adapter = CodexBackendSession(
            runtime: AdapterCodexRuntime(
                toolResult: .failure("Error: file was not readable.")
            ),
            turboThreadID: "thread-tool-failure",
            agentTuning: AgentTuningConfig()
        )
        let capture = RuntimeEventCapture()

        _ = await adapter.run(
            request: TurnRequest(
                prompt: "Run a failing Codex tool.",
                backend: .codex,
                modelName: "Codex test model",
                workspaceRoot: "/tmp"
            ),
            events: BackendSessionEvents { event in
                await capture.append(event)
            }
        )
        let received = await capture.events

        let toolResult = received.compactMap { event -> ToolResult? in
            guard case .toolFinished(let result) = event else { return nil }
            return result
        }.first
        #expect(toolResult?.status == .failed)
        #expect(toolResult?.output == "Error: file was not readable.")
    }

    @Test("Codex backend adapter maps authentication failures to recoverable outcomes")
    func codexBackendAdapterMapsAuthenticationFailure() async {
        let adapter = CodexBackendSession(
            runtime: FailingAdapterCodexRuntime(
                error: CodexAppServerError.chatGPTLoginRequired
            ),
            turboThreadID: "thread-auth",
            agentTuning: AgentTuningConfig()
        )

        let result = await adapter.run(
            request: TurnRequest(
                prompt: "Authenticate Codex.",
                backend: .codex,
                modelName: "Codex test model",
                workspaceRoot: "/tmp"
            ),
            events: .none
        )

        #expect(
            result.outcome
                == .failed(
                    TurnFailure(
                        code: "codex.authentication",
                        message: "Codex authentication is required.",
                        isRecoverable: true
                    )
                )
        )
    }

    @Test("Cancelling a Codex backend session interrupts the provider runtime")
    func cancellingCodexBackendSessionInterruptsRuntime() async {
        let runtime = BlockingAdapterCodexRuntime()
        let adapter = CodexBackendSession(
            runtime: runtime,
            turboThreadID: "thread-cancel",
            agentTuning: AgentTuningConfig()
        )
        let task = Task { @MainActor in
            await adapter.run(
                request: TurnRequest(
                    prompt: "Cancel Codex.",
                    backend: .codex,
                    modelName: "Codex test model",
                    workspaceRoot: "/tmp"
                ),
                events: .none
            )
        }

        await runtime.waitUntilStarted()
        task.cancel()
        let result = await task.value

        #expect(result.outcome == .cancelled(reason: "The turn was interrupted."))
        #expect(await runtime.interrupted)
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
            acceptanceCriteria: ["Activity reaches the matching terminal state."]
        )
    }
}

private actor RuntimeEventCapture {
    private var storedEvents: [AgentRuntimeEvent] = []

    func append(_ event: AgentRuntimeEvent) {
        storedEvents.append(event)
    }

    var events: [AgentRuntimeEvent] {
        storedEvents
    }
}

private actor ParentTurnRecorder {
    private(set) var value: TurnID?

    func record(_ value: TurnID?) {
        self.value = value
    }
}

private nonisolated struct ParentTurnRecordingRunner: AgentTaskRunning {
    let recorder: ParentTurnRecorder

    @MainActor
    func run(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async -> AgentTaskResult {
        await recorder.record(envelope.parentTurnID)
        return try! AgentTaskResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            outcome: .completed,
            technicalSummary: "Parent turn recorded."
        )
    }
}

@MainActor
private final class AdapterNativeRunner: NativeResponseRunning {
    let outcome: NativeResponseRunner.Outcome

    init(outcome: NativeResponseRunner.Outcome) {
        self.outcome = outcome
    }

    func run(
        session: LanguageModelSession,
        request: NativeResponseRunner.Request,
        events: NativeResponseRunner.Events
    ) async -> NativeResponseRunner.Outcome {
        outcome
    }
}

nonisolated private final class AdapterCodexRuntime: CodexTurnRunning, Sendable {
    private let toolResult: CodexDynamicToolResult
    private let receipt: ToolReceipt?

    init(
        toolResult: CodexDynamicToolResult = .success("file contents"),
        receipt: ToolReceipt? = nil
    ) {
        self.toolResult = toolResult
        self.receipt = receipt
    }

    func runTurn(
        request: CodexTurnRequest,
        events: CodexTurnEvents
    ) async throws -> CodexTurnResult {
        await events.liveAssistantChanged("Codex result.")
        await events.liveReasoningChanged("Codex reasoning.")
        let call = CodexDynamicToolCall(
            rpcID: .integer(1),
            callID: "codex-tool",
            tool: "read_file",
            arguments: .object(["filePath": .string("App.swift")])
        )
        await events.activityStarted(call, "Reading file")
        // The adapter test double carries the same typed receipt as a real
        // Codex tool bridge so the runtime boundary, not UI reconstruction,
        // remains responsible for preserving structured tool output.
        await events.toolFinished(call, toolResult, receipt)
        await events.activityEnded(call.callID)
        return CodexTurnResult(
            assistantText: "Codex result.",
            reasoningText: "Codex reasoning."
        )
    }

    func interrupt() async {}
}

/// Provider doubles for terminal error and cancellation paths. The blocking
/// runtime deliberately ignores task cancellation until the adapter forwards
/// its explicit provider interrupt, which keeps that boundary observable.
private actor FailingAdapterCodexRuntime: CodexTurnRunning {
    let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func runTurn(
        request: CodexTurnRequest,
        events: CodexTurnEvents
    ) async throws -> CodexTurnResult {
        throw error
    }

    func interrupt() async {}
}

private actor BlockingAdapterCodexRuntime: CodexTurnRunning {
    private var continuation: CheckedContinuation<
        CodexTurnResult,
        Error
    >?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false
    private(set) var interrupted = false

    func runTurn(
        request: CodexTurnRequest,
        events: CodexTurnEvents
    ) async throws -> CodexTurnResult {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func interrupt() async {
        interrupted = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
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
