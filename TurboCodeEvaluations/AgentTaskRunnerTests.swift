import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Agent task runner")
struct AgentTaskRunnerTests {
    @Test("Bounded runner maps worker output and failures to typed results")
    func mapsWorkerResults() async throws {
        let envelope = try makeEnvelope()
        let success = BoundedAgentTaskRunner(
            worker: ScriptedAgentTaskWorker(behavior: .content("Implemented the focused change."))
        )
        let failure = BoundedAgentTaskRunner(
            worker: ScriptedAgentTaskWorker(behavior: .failure)
        )

        let completed = await success.run(
            envelope: envelope,
            context: makeContext(),
            events: .none
        )
        let failed = await failure.run(
            envelope: envelope,
            context: makeContext(),
            events: .none
        )

        #expect(completed.outcome == .completed)
        #expect(completed.technicalSummary == "Implemented the focused change.")
        #expect(failed.outcome == .failed)
        #expect(failed.failureReason == .workerFailed)
    }

    @Test("Runner timeout cancels a suspended worker")
    func timesOutWorker() async throws {
        let envelope = try makeEnvelope(
            budget: DelegationBudget(timeoutSeconds: 1, maximumToolCalls: 2)
        )
        let runner = BoundedAgentTaskRunner(
            worker: ScriptedAgentTaskWorker(behavior: .suspended)
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = await runner.run(
            envelope: envelope,
            context: makeContext(),
            events: .none
        )

        #expect(result.outcome == .failed)
        #expect(result.failureReason == .timedOut)
        #expect(startedAt.duration(to: clock.now) < .seconds(2))
    }

    @Test("Caller cancellation produces a cancelled terminal result")
    func propagatesCancellation() async throws {
        let envelope = try makeEnvelope()
        let runner = BoundedAgentTaskRunner(
            worker: ScriptedAgentTaskWorker(behavior: .suspended)
        )
        let task = Task { @MainActor in
            await runner.run(
                envelope: envelope,
                context: makeContext(),
                events: .none
            )
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.value

        #expect(result.outcome == .cancelled)
        #expect(result.failureReason == .cancelled)
    }

    @Test("Verification starts after the last worker mutation and owns Verified")
    func verifiesAfterWorkerMutation() async throws {
        let envelope = try AgentTaskEnvelope(
            taskID: "task-verification",
            attemptID: "attempt-verification",
            goal: "Apply one edit and verify it.",
            acceptanceCriteria: ["The deterministic build passes."],
            allowedTools: [.editFile],
            verificationRequest: .build,
            verificationParameters: AgentVerificationParameters(
                scheme: "Fixture"
            )
        )
        let verifier = RecordingAgentTaskVerifier(succeeds: true)
        let order = AgentTaskTestEventOrder()
        let runner = BoundedAgentTaskRunner(
            worker: MutatingAgentTaskWorker(),
            verifier: verifier
        )

        let result = await runner.run(
            envelope: envelope,
            context: makeContext(),
            events: AgentTaskRunnerEvents(
                toolFinished: { _ in await order.append("mutation") },
                verificationStarted: { _, _, _ in
                    await order.append("verification")
                }
            )
        )

        #expect(await order.values == ["mutation", "verification"])
        #expect(await verifier.observedMutationSequence == 1)
        #expect(result.outcome == .verified)
        #expect(result.verification.status == .passed)
        #expect(result.verification.receiptID == "verification-receipt")
        #expect(result.receiptIDs == ["verification-receipt"])
    }

    @Test("A mutation arriving during verification invalidates passing evidence")
    func lateMutationInvalidatesVerification() async throws {
        let envelope = try AgentTaskEnvelope(
            taskID: "task-stale-verification",
            attemptID: "attempt-stale-verification",
            goal: "Apply edits and verify the final state.",
            acceptanceCriteria: ["Only the latest workspace state is verified."],
            allowedTools: [.editFile],
            verificationRequest: .test
        )
        let runner = BoundedAgentTaskRunner(
            worker: LateMutatingAgentTaskWorker(),
            verifier: RecordingAgentTaskVerifier(
                succeeds: true,
                delay: .milliseconds(40)
            )
        )

        let result = await runner.run(
            envelope: envelope,
            context: makeContext(),
            events: .none
        )

        #expect(result.outcome == .failed)
        #expect(result.failureReason == .verificationInvalidated)
        #expect(result.verification.status == .failed)
        #expect(result.unresolvedWork == ["Run verification again."])
    }

    @Test("Revision conflicts become typed failures before verification")
    func revisionConflictFailsClosed() async throws {
        let envelope = try AgentTaskEnvelope(
            taskID: "task-conflict",
            attemptID: "attempt-conflict",
            goal: "Edit the latest file revision.",
            acceptanceCriteria: ["No stale content is overwritten."],
            allowedTools: [.editFile],
            verificationRequest: .build
        )
        let verifier = RecordingAgentTaskVerifier(succeeds: true)
        let runner = BoundedAgentTaskRunner(
            worker: RevisionConflictAgentTaskWorker(),
            verifier: verifier
        )

        let result = await runner.run(
            envelope: envelope,
            context: makeContext(),
            events: .none
        )

        #expect(result.outcome == .failed)
        #expect(result.failureReason == .revisionConflict)
        #expect(result.verification.status == .notRequested)
        #expect(result.unresolvedWork == ["Re-read Counter.swift before editing again."])
        #expect(await verifier.observedMutationSequence == nil)
    }

    @Test("Execution gate enforces allowlist and maximum tool calls")
    func enforcesToolBudget() async {
        let gate = AgentTaskExecutionGate(
            allowedToolNames: ["read_file"],
            maximumToolCalls: 1
        )

        #expect(await gate.beginTool(named: "read_file") == nil)
        #expect(await gate.count == 1)
        #expect(await gate.beginTool(named: "read_file") == .toolLimitReached)

        let restricted = AgentTaskExecutionGate(
            allowedToolNames: ["read_file"],
            maximumToolCalls: 4
        )
        #expect(await restricted.beginTool(named: "git") == .toolNotAllowed("git"))
        #expect(await restricted.count == 0)
    }

    @Test("Effective allowlist is the task and catalog-plan intersection")
    func intersectsTaskAllowlistWithCatalogPlan() throws {
        let envelope = try AgentTaskEnvelope(
            taskID: "allowlist-task",
            attemptID: "allowlist-attempt",
            goal: "Inspect source without changing repository state.",
            acceptanceCriteria: ["Read the requested source."],
            allowedTools: [.readFile, .git]
        )
        let plan = ModelToolPlan(
            profile: .delegate,
            tier: .standard,
            assignments: [
                .init(id: .readFile, isRegistered: true, unavailableReason: nil),
                .init(id: .git, isRegistered: false, unavailableReason: "Restricted")
            ]
        )

        #expect(
            AgentTaskToolPolicy.permittedNames(envelope: envelope, plan: plan)
                == ["read_file"]
        )
    }

    @Test("Compatibility tool converts free text into a correlated envelope")
    func compatibilityToolUsesInjectedRunner() async throws {
        let fake = RecordingFakeAgentTaskRunner()
        let plan = ModelToolPlan(
            profile: .delegate,
            tier: .standard,
            assignments: [
                ModelToolAssignment(id: .readFile, isRegistered: true, unavailableReason: nil),
                ModelToolAssignment(id: .editFile, isRegistered: true, unavailableReason: nil)
            ]
        )
        let tool = CallPowerfulModelTool(
            model: SystemLanguageModel.default,
            temperature: nil,
            reasoningLevel: nil,
            delegatePlan: plan,
            delegateTools: [],
            delegateInstructions: "Complete the delegated Swift task.",
            runner: fake
        )

        let output = try await tool.call(
            arguments: CallPowerfulModelArguments(task: "Update Parser.swift")
        )
        let envelope = try #require(fake.lastEnvelope)

        #expect(output == "Fake worker completed the task.")
        #expect(envelope.goal == "Update Parser.swift")
        #expect(envelope.taskID != envelope.attemptID)
        #expect(envelope.allowedTools == [.editFile, .readFile])
    }

    private func makeEnvelope(
        budget: DelegationBudget = DelegationBudget(
            timeoutSeconds: 5,
            maximumToolCalls: 2
        )
    ) throws -> AgentTaskEnvelope {
        try AgentTaskEnvelope(
            taskID: "task-runner",
            attemptID: "attempt-runner",
            goal: "Make one focused Swift change.",
            acceptanceCriteria: ["The requested behavior is implemented."],
            allowedTools: [.readFile],
            budget: budget
        )
    }

    private func makeContext() -> AgentTaskRunContext {
        AgentTaskRunContext(
            model: SystemLanguageModel.default,
            toolPlan: ModelToolPlan(
                profile: .delegate,
                tier: .standard,
                assignments: []
            ),
            tools: [],
            instructions: "Complete the task.",
            temperature: nil,
            reasoningLevel: nil
        )
    }
}

private struct ScriptedAgentTaskWorker: AgentTaskWorkerExecuting {
    enum Behavior: Sendable {
        case content(String)
        case failure
        case suspended
    }

    enum Failure: LocalizedError {
        case expected

        var errorDescription: String? { "Expected fake worker failure." }
    }

    let behavior: Behavior

    @MainActor
    func execute(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String {
        switch behavior {
        case .content(let value):
            return value
        case .failure:
            throw Failure.expected
        case .suspended:
            try await Task.sleep(for: .seconds(60))
            return "Unexpected completion"
        }
    }
}

private struct MutatingAgentTaskWorker: AgentTaskWorkerExecuting {
    @MainActor
    func execute(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String {
        let call = Transcript.ToolCall(
            id: "edit-call",
            toolName: ToolCapabilityID.editFile.rawValue,
            arguments: GeneratedContent(
                properties: ["filePath": "Fixture.swift"]
            )
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
                    segments: [.text(.init(content: "Edit applied."))]
                )
            )
        )
        return "Applied the requested edit."
    }
}

private struct LateMutatingAgentTaskWorker: AgentTaskWorkerExecuting {
    @MainActor
    func execute(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String {
        let first = mutationCall(id: "edit-before-verification")
        await finish(first, envelope: envelope, events: events)

        // A misbehaving provider may finish a tool after its response stream
        // returns. The runner must treat this as a newer workspace revision.
        Task {
            try? await Task.sleep(for: .milliseconds(10))
            let late = mutationCall(id: "edit-during-verification")
            await finish(late, envelope: envelope, events: events)
        }
        return "Applied the requested edits."
    }

    private func mutationCall(id: String) -> Transcript.ToolCall {
        Transcript.ToolCall(
            id: id,
            toolName: ToolCapabilityID.editFile.rawValue,
            arguments: GeneratedContent(
                properties: ["filePath": "Fixture.swift"]
            )
        )
    }

    private func finish(
        _ call: Transcript.ToolCall,
        envelope: AgentTaskEnvelope,
        events: AgentTaskRunnerEvents
    ) async {
        await events.toolFinished(
            AgentTaskToolOutputEvent(
                taskID: envelope.taskID,
                attemptID: envelope.attemptID,
                call: call,
                output: Transcript.ToolOutput(
                    id: call.id,
                    toolName: call.toolName,
                    segments: [.text(.init(content: "Edit applied."))]
                )
            )
        )
    }
}

private struct RevisionConflictAgentTaskWorker: AgentTaskWorkerExecuting {
    @MainActor
    func execute(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String {
        let call = Transcript.ToolCall(
            id: "revision-conflict",
            toolName: ToolCapabilityID.editFile.rawValue,
            arguments: GeneratedContent(
                properties: ["filePath": "Counter.swift"]
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
                        .text(
                            .init(
                                content: """
                                TURBOCODE_REVISION_CONFLICT
                                path: Counter.swift
                                Edit transaction rejected.
                                """
                            )
                        )
                    ]
                )
            )
        )
        return "The edit could not be applied."
    }
}

private actor RecordingAgentTaskVerifier: AgentTaskVerificationRunning {
    let succeeds: Bool
    let delay: Duration?
    private(set) var observedMutationSequence: Int?

    init(succeeds: Bool, delay: Duration? = nil) {
        self.succeeds = succeeds
        self.delay = delay
    }

    func verify(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        mutationSequence: Int
    ) async -> AgentTaskVerificationReceipt {
        observedMutationSequence = mutationSequence
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return AgentTaskVerificationReceipt(
            id: "verification-receipt",
            request: envelope.verificationRequest,
            mutationSequence: mutationSequence,
            succeeded: succeeds,
            cancelled: false,
            summary: succeeds ? "Build succeeded." : "Build failed."
        )
    }
}

private actor AgentTaskTestEventOrder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class RecordingFakeAgentTaskRunner: AgentTaskRunning {
    private(set) var lastEnvelope: AgentTaskEnvelope?

    func run(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async -> AgentTaskResult {
        lastEnvelope = envelope
        return try! AgentTaskResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            outcome: .completed,
            technicalSummary: "Fake worker completed the task."
        )
    }
}
