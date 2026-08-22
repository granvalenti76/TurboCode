import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("M4.2 delegated task scenarios")
struct AgentEndToEndScenarioTests {
    @Test("Reasoning accumulation accepts cumulative snapshots and deltas")
    func reasoningAccumulationHandlesProviderUpdateShapes() {
        var reasoning = "Think"
        reasoning = NativeResponseRunner.accumulatedReasoning(
            previous: reasoning,
            incoming: "Think step"
        )
        #expect(reasoning == "Think step")

        reasoning = NativeResponseRunner.accumulatedReasoning(
            previous: reasoning,
            incoming: " two"
        )
        #expect(reasoning == "Think step two")

        reasoning = NativeResponseRunner.accumulatedReasoning(
            previous: reasoning,
            incoming: "Think"
        )
        #expect(reasoning == "Think step two")
    }

    @Test("Delegated edit reaches the chat timeline without coordinator policy fields")
    func successfulDelegatedEditCompletesEndToEnd() async throws {
        let fixture = try ScenarioWorkspace()
        defer { fixture.remove() }
        let activity = AgentActivityStore()
        let verifier = ScenarioVerifier(
            fileURL: fixture.fileURL,
            expectedContent: ScenarioWorkspace.editedContent
        )
        let invoker = makeInvoker(
            worker: ScenarioEditingWorker(
                workspaceRoot: fixture.root.path,
                suspendsAfterEdit: false
            ),
            verifier: verifier,
            activity: activity
        )
        let timeline = ChatTimelineStore()
        let response = makeResponseCoordinator(
            timeline: timeline,
            activity: activity
        ) {
            let output = try! await DelegateTaskTool(invoker: invoker).call(
                arguments: Self.arguments(attemptID: "attempt-success")
            )
            return .completed(content: output, reasoning: "")
        }

        let turnID = TurnID(rawValue: "turn-success")
        let responseResult = await response.performNative(
            displayText: "Increment the fixture value and run its focused test.",
            promptText: "Delegate the focused edit.",
            visibleInTimeline: true,
            turnID: turnID,
            blocks: [],
            session: LanguageModelSession(),
            backend: .foundationApple,
            mode: .standalone,
            workspaceKind: "swift-fixture",
            workspaceRoot: fixture.root.path,
            modelName: "Scenario Coordinator"
        )

        let result = try decodedResult(from: timeline.blocks.last?.text)
        #expect(responseResult.errorMessage == nil)
        #expect(responseResult.touchedConversation)
        #expect(result.outcome == .completed)
        #expect(result.verification.status == .notRequested)
        #expect(activity.current?.phase == .succeeded)
        #expect(activity.current?.lastOperationalPhase == .workerRunning)
        #expect(activity.current?.finalResult == result)
        #expect(response.currentTurnState?.id == turnID)
        #expect(response.currentTurnState?.phase == .completed)
        #expect(timeline.runtimeSnapshot?.turn?.id == turnID)
        #expect(timeline.runtimeSnapshot?.turn?.phase == .completed)
        #expect(timeline.runtimeSnapshot?.isQuiescing == false)
        #expect(timeline.activeAssistantPlaceholderID == nil)
        #expect(try String(contentsOf: fixture.fileURL, encoding: .utf8)
            == ScenarioWorkspace.editedContent)
        #expect(await verifier.invocationCount == 0)
    }

    @Test("Empty worker output fails closed and exposes one recovery")
    func emptyWorkerOutputOffersRecoveryWithoutVerification() async throws {
        let fixture = try ScenarioWorkspace()
        defer { fixture.remove() }
        let activity = AgentActivityStore()
        let verifier = ScenarioVerifier(
            fileURL: fixture.fileURL,
            expectedContent: ScenarioWorkspace.editedContent
        )
        let invoker = makeInvoker(
            worker: ScenarioEmptyWorker(),
            verifier: verifier,
            activity: activity
        )
        let timeline = ChatTimelineStore()
        let response = makeResponseCoordinator(
            timeline: timeline,
            activity: activity
        ) {
            let output = try! await DelegateTaskTool(invoker: invoker).call(
                arguments: Self.arguments(attemptID: "attempt-empty")
            )
            return .completed(content: output, reasoning: "")
        }

        let turnID = TurnID(rawValue: "turn-empty")
        _ = await response.performNative(
            displayText: "Delegate the focused edit.",
            promptText: "Delegate the focused edit.",
            visibleInTimeline: true,
            turnID: turnID,
            blocks: [],
            session: LanguageModelSession(),
            backend: .foundationApple,
            mode: .standalone,
            workspaceKind: "swift-fixture",
            workspaceRoot: fixture.root.path,
            modelName: "Scenario Coordinator"
        )

        let result = try decodedResult(from: timeline.blocks.last?.text)
        let recovery = try #require(
            AgentRecoveryPresentation(
                result: result,
                reviewableReceiptID: nil
            )
        )
        #expect(result.outcome == .failed)
        #expect(result.failureReason == .invalidResult)
        #expect(result.verification.status == .notRequested)
        #expect(result.receiptIDs.isEmpty)
        #expect(activity.current?.phase == .failed)
        #expect(activity.current?.activeTool == nil)
        #expect(response.currentTurnState?.id == turnID)
        #expect(timeline.runtimeSnapshot?.turn?.id == turnID)
        #expect(timeline.runtimeSnapshot?.turn?.phase == .completed)
        // The provider turn completed successfully; the embedded delegated
        // task result is the failure surfaced by the scenario above.
        #expect(response.currentTurnState?.phase == .completed)
        #expect(recovery.action == .prepareRetry)
        #expect(recovery.title == "Prepare New Attempt")
        #expect(await verifier.invocationCount == 0)
        #expect(try String(contentsOf: fixture.fileURL, encoding: .utf8)
            == ScenarioWorkspace.originalContent)
    }

    @Test("Stop during a worker tool closes Activity and the response placeholder")
    func cancellationClosesTheVerticalSliceAndPreservesAppliedChanges() async throws {
        let fixture = try ScenarioWorkspace()
        defer { fixture.remove() }
        let activity = AgentActivityStore()
        let verifier = ScenarioVerifier(
            fileURL: fixture.fileURL,
            expectedContent: ScenarioWorkspace.editedContent
        )
        let invoker = makeInvoker(
            worker: ScenarioEditingWorker(
                workspaceRoot: fixture.root.path,
                suspendsAfterEdit: true
            ),
            verifier: verifier,
            activity: activity
        )
        let timeline = ChatTimelineStore()
        let response = makeResponseCoordinator(
            timeline: timeline,
            activity: activity
        ) {
            let output = try! await DelegateTaskTool(invoker: invoker).call(
                arguments: Self.arguments(attemptID: "attempt-cancel")
            )
            let result = try! JSONDecoder().decode(
                AgentTaskResult.self,
                from: Data(output.utf8)
            )
            if result.outcome == .cancelled {
                return .cancelled(partialContent: "", reasoning: "")
            }
            return .completed(content: output, reasoning: "")
        }
        let turnID = TurnID(rawValue: "turn-cancel")
        let task = Task { @MainActor in
            await response.performNative(
                displayText: "Delegate and stop the focused edit.",
                promptText: "Delegate the focused edit.",
                visibleInTimeline: true,
                turnID: turnID,
                blocks: [],
                session: LanguageModelSession(),
                backend: .foundationApple,
                mode: .standalone,
                workspaceKind: "swift-fixture",
                workspaceRoot: fixture.root.path,
                modelName: "Scenario Coordinator"
            )
        }

        // Wait until the post-edit tool is visibly active. Cancelling here
        // reproduces the user pressing Stop after a valid change was applied.
        while activity.current?.activeTool?.callID != "scenario-suspended-tool" {
            await Task.yield()
        }
        task.cancel()
        _ = await task.value

        #expect(activity.current?.phase == .cancelled)
        #expect(activity.current?.finalResult?.outcome == .cancelled)
        #expect(response.currentTurnState?.id == turnID)
        #expect(response.currentTurnState?.phase == .cancelled)
        #expect(timeline.runtimeSnapshot?.turn?.id == turnID)
        #expect(timeline.runtimeSnapshot?.turn?.phase == .cancelled)
        #expect(activity.current?.activeTool == nil)
        #expect(timeline.activeAssistantPlaceholderID == nil)
        #expect(timeline.liveAssistant.isEmpty)
        #expect(timeline.liveReasoning.isEmpty)
        #expect(timeline.blocks.last?.text == "Response interrupted.")
        #expect(await verifier.invocationCount == 0)
        // Cancellation does not roll back a completed atomic edit; the changed
        // file remains available to the normal diff/review workflow.
        #expect(try String(contentsOf: fixture.fileURL, encoding: .utf8)
            == ScenarioWorkspace.editedContent)
    }

    private func makeInvoker(
        worker: any AgentTaskWorkerExecuting,
        verifier: any AgentTaskVerificationRunning,
        activity: AgentActivityStore
    ) -> ConfiguredAgentTaskInvoker {
        let events = AgentTaskRunnerEvents(
            toolStarted: { event in
                await activity.apply(
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
                await activity.apply(
                    .toolFinished(
                        taskID: event.taskID,
                        attemptID: event.attemptID,
                        callID: event.call.id
                    )
                )
            },
            verificationStarted: { taskID, attemptID, _ in
                await activity.apply(
                    .phaseChanged(
                        taskID: taskID,
                        attemptID: attemptID,
                        phase: .verifying
                    )
                )
            }
        )
        return ConfiguredAgentTaskInvoker(
            runner: BoundedAgentTaskRunner(
                worker: worker,
                verifier: verifier
            ),
            context: AgentTaskRunContext(
                model: SystemLanguageModel.default,
                tools: [],
                instructions: "Complete the deterministic release scenario.",
                temperature: nil,
                reasoningLevel: nil
            ),
            events: events,
            coordinator: .init(
                modelName: "Scenario Coordinator",
                role: .powerfulCoordinator
            ),
            worker: .init(
                modelName: "Scenario Worker",
                role: .codingWorker
            ),
            activityChanged: { event in
                await activity.apply(event)
            }
        )
    }

    private func makeResponseCoordinator(
        timeline: ChatTimelineStore,
        activity: AgentActivityStore,
        operation: @escaping @MainActor @Sendable () async
            -> NativeResponseRunner.Outcome
    ) -> ChatResponseCoordinator {
        ChatResponseCoordinator(
            timeline: timeline,
            toolInteractions: ToolInteractionStore(),
            agentActivity: activity,
            codexRuntime: CodexRuntimeStore(),
            nativeRunner: ScenarioNativeResponseRunner(operation: operation)
        )
    }

    private static func arguments(attemptID: String) -> DelegateTaskArguments {
        DelegateTaskArguments(
            mode: "coding",
            goal: "Increment Sources/Counter.swift and report the completed edit for \(attemptID)."
        )
    }

    private func decodedResult(from text: String?) throws -> AgentTaskResult {
        let text = try #require(text)
        return try JSONDecoder().decode(
            AgentTaskResult.self,
            from: Data(text.utf8)
        )
    }
}

@MainActor
private final class ScenarioNativeResponseRunner: NativeResponseRunning {
    let operation: @MainActor @Sendable () async -> NativeResponseRunner.Outcome

    init(
        operation: @escaping @MainActor @Sendable () async
            -> NativeResponseRunner.Outcome
    ) {
        self.operation = operation
    }

    func run(
        session: LanguageModelSession,
        request: NativeResponseRunner.Request,
        events: NativeResponseRunner.Events
    ) async -> NativeResponseRunner.Outcome {
        await operation()
    }
}

private struct ScenarioEditingWorker: AgentTaskWorkerExecuting {
    let workspaceRoot: String
    let suspendsAfterEdit: Bool

    @MainActor
    func execute(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String {
        let readCall = Transcript.ToolCall(
            id: "scenario-read",
            toolName: ToolCapabilityID.readFile.rawValue,
            arguments: GeneratedContent(
                properties: ["filePath": "Sources/Counter.swift"]
            )
        )
        await events.toolStarted(.init(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            call: readCall
        ))
        let readOutput = try await ReadFileTool(workspaceRoot: workspaceRoot).call(
            arguments: ReadFileArguments(
                filePath: "Sources/Counter.swift",
                startLine: 1,
                endLine: 3,
                limit: nil
            )
        )
        await events.toolFinished(Self.finished(
            readCall,
            output: readOutput,
            envelope: envelope
        ))
        let revision = try Self.revision(from: readOutput)

        let editCall = Transcript.ToolCall(
            id: "scenario-edit",
            toolName: ToolCapabilityID.editFile.rawValue,
            arguments: GeneratedContent(
                properties: ["filePath": "Sources/Counter.swift"]
            )
        )
        await events.toolStarted(.init(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            call: editCall
        ))
        let editOutput = try await EditFileTool(
            workspaceRoot: workspaceRoot,
            reportsChanges: false
        ).call(
            arguments: EditFileArguments(
                filePath: "Sources/Counter.swift",
                revision: revision,
                operation: "replace_lines",
                startLine: 2,
                endLine: 2,
                content: "    static let value = 2"
            )
        )
        await events.toolFinished(Self.finished(
            editCall,
            output: editOutput,
            envelope: envelope
        ))

        if suspendsAfterEdit {
            let suspendedCall = Transcript.ToolCall(
                id: "scenario-suspended-tool",
                toolName: ToolCapabilityID.readFile.rawValue,
                arguments: GeneratedContent(
                    properties: ["filePath": "Sources/Counter.swift"]
                )
            )
            await events.toolStarted(.init(
                taskID: envelope.taskID,
                attemptID: envelope.attemptID,
                call: suspendedCall
            ))
            try await Task.sleep(for: .seconds(60))
        }
        return "Updated Counter.value with a revision-aware edit."
    }

    private static func revision(from output: String) throws -> String {
        let prefix = "Revision: "
        guard let line = output.split(separator: "\n")
            .first(where: { $0.hasPrefix(prefix) }) else {
            throw ScenarioFailure.missingRevision
        }
        return String(line.dropFirst(prefix.count))
    }

    private static func finished(
        _ call: Transcript.ToolCall,
        output: String,
        envelope: AgentTaskEnvelope
    ) -> AgentTaskToolOutputEvent {
        AgentTaskToolOutputEvent(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            call: call,
            output: Transcript.ToolOutput(
                id: call.id,
                toolName: call.toolName,
                segments: [.text(.init(content: output))]
            )
        )
    }
}

private struct ScenarioEmptyWorker: AgentTaskWorkerExecuting {
    @MainActor
    func execute(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String {
        " \n "
    }
}

private actor ScenarioVerifier: AgentTaskVerificationRunning {
    let fileURL: URL
    let expectedContent: String
    private(set) var invocationCount = 0

    init(fileURL: URL, expectedContent: String) {
        self.fileURL = fileURL
        self.expectedContent = expectedContent
    }

    func verify(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        mutationSequence: Int
    ) async -> AgentTaskVerificationReceipt {
        invocationCount += 1
        let content = try? String(contentsOf: fileURL, encoding: .utf8)
        let succeeded = content == expectedContent
        return AgentTaskVerificationReceipt(
            id: "scenario-verification",
            request: envelope.verificationRequest,
            mutationSequence: mutationSequence,
            succeeded: succeeded,
            cancelled: false,
            summary: succeeded
                ? "Focused fixture test passed."
                : "Focused fixture test failed."
        )
    }
}

private struct ScenarioWorkspace {
    static let originalContent = """
    enum Counter {
        static let value = 1
    }

    """
    static let editedContent = """
    enum Counter {
        static let value = 2
    }

    """

    let root: URL
    let fileURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TurboCode M4.2 \(UUID().uuidString)",
                isDirectory: true
            )
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sources,
            withIntermediateDirectories: true
        )
        fileURL = sources.appendingPathComponent("Counter.swift")
        try Self.originalContent.write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum ScenarioFailure: Error {
    case missingRevision
}
