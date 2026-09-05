import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Agent Activity state machine")
struct AgentActivityStoreTests {
    @Test("Lifecycle graph accepts every declared transition")
    func acceptsEveryValidTransition() {
        let validTransitions: Set<PhaseTransition> = [
            .init(from: .preparing, to: .delegating),
            .init(from: .preparing, to: .failed),
            .init(from: .preparing, to: .cancelled),
            .init(from: .delegating, to: .workerRunning),
            .init(from: .delegating, to: .failed),
            .init(from: .delegating, to: .cancelled),
            .init(from: .workerRunning, to: .verifying),
            .init(from: .workerRunning, to: .succeeded),
            .init(from: .workerRunning, to: .failed),
            .init(from: .workerRunning, to: .cancelled),
            .init(from: .verifying, to: .succeeded),
            .init(from: .verifying, to: .failed),
            .init(from: .verifying, to: .cancelled)
        ]

        for source in allPhases {
            for destination in allPhases {
                #expect(
                    source.canTransition(to: destination)
                        == validTransitions.contains(
                            .init(from: source, to: destination)
                        )
                )
            }
        }
    }

    @Test("Store preserves route, timing, active tool, and final result")
    func preservesActivityData() throws {
        let store = AgentActivityStore()
        let envelope = try makeEnvelope()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = AgentActivityAgent(
            modelName: "DeepSeek",
            role: .powerfulCoordinator
        )
        let worker = AgentActivityAgent(
            modelName: "Local Llama",
            role: .codingWorker
        )
        let tool = AgentActivityTool(
            callID: "call-1",
            name: "read_file",
            owner: .worker
        )

        #expect(
            store.begin(
                envelope: envelope,
                coordinator: coordinator,
                worker: worker,
                startedAt: startedAt
            )
        )
        #expect(store.advance(envelope, to: .delegating))
        #expect(store.advance(envelope, to: .workerRunning))
        #expect(store.beginTool(tool, envelope: envelope))
        #expect(store.current?.activeTool == tool)
        #expect(store.finishTool(callID: tool.callID, envelope: envelope))

        let result = try makeResult(envelope: envelope, outcome: .completed)
        #expect(store.complete(with: result))
        #expect(store.current?.taskID == envelope.taskID)
        #expect(store.current?.attemptID == envelope.attemptID)
        #expect(store.current?.goal == envelope.goal)
        #expect(store.current?.verificationRequest == envelope.verificationRequest)
        #expect(store.current?.coordinator == coordinator)
        #expect(store.current?.worker == worker)
        #expect(store.current?.phase == .succeeded)
        #expect(store.current?.lastOperationalPhase == .workerRunning)
        #expect(store.current?.activeTool == nil)
        #expect(store.current?.startedAt == startedAt)
        #expect(store.current?.completedAt != nil)
        #expect(store.current?.finalResult == result)
    }

    @Test("Verified, failed, and cancelled results map to terminal phases")
    func mapsEveryTerminalResult() throws {
        let cases: [(AgentTaskOutcome, AgentActivityPhase)] = [
            (.verified, .succeeded),
            (.failed, .failed),
            (.cancelled, .cancelled)
        ]

        for (outcome, expectedPhase) in cases {
            let store = AgentActivityStore()
            let envelope = try makeEnvelope(attemptID: "attempt-\(outcome.rawValue)")
            #expect(store.beginTestAttempt(envelope))
            if outcome == .verified {
                #expect(store.advance(envelope, to: .delegating))
                #expect(store.advance(envelope, to: .workerRunning))
                #expect(store.advance(envelope, to: .verifying))
            }

            let result = try makeResult(envelope: envelope, outcome: outcome)
            #expect(store.complete(with: result))
            #expect(store.current?.phase == expectedPhase)
            #expect(store.current?.finalResult == result)
        }
    }

    @Test("Concurrent workers retain independent activity and selection")
    func retainsConcurrentWorkers() throws {
        let store = AgentActivityStore()
        let first = try makeEnvelope(attemptID: "attempt-a")
        let second = try makeEnvelope(attemptID: "attempt-b")

        #expect(store.beginTestAttempt(first))
        #expect(store.beginTestAttempt(second))
        #expect(store.activities.count == 2)
        #expect(store.current?.attemptID == second.attemptID)

        #expect(store.advance(first, to: .delegating))
        #expect(store.advance(first, to: .workerRunning))
        #expect(store.activities.first?.phase == .workerRunning)
        #expect(store.activities.last?.phase == .preparing)

        store.select(store.activities[0].id)
        #expect(store.current?.attemptID == first.attemptID)
    }

    @Test("Out-of-order phases and mismatched attempt events are ignored")
    func ignoresOutOfOrderEvents() throws {
        let store = AgentActivityStore()
        let envelope = try makeEnvelope()
        #expect(store.beginTestAttempt(envelope))

        #expect(!store.advance(envelope, to: .workerRunning))
        #expect(!store.advance(envelope, to: .verifying))
        #expect(
            !store.advance(
                taskID: envelope.taskID,
                attemptID: "other-attempt",
                to: .delegating
            )
        )
        #expect(store.current?.phase == .preparing)
        #expect(store.advance(envelope, to: .delegating))
        #expect(!store.advance(envelope, to: .preparing))
        #expect(store.current?.phase == .delegating)
    }

    @Test("Late events cannot mutate or restart a completed attempt")
    func ignoresLateEventsForCompletedAttempt() throws {
        let store = AgentActivityStore()
        let envelope = try makeEnvelope()
        #expect(store.beginTestAttempt(envelope))
        #expect(store.advance(envelope, to: .delegating))
        #expect(store.advance(envelope, to: .workerRunning))
        let result = try makeResult(envelope: envelope, outcome: .completed)
        #expect(store.complete(with: result))

        let lateTool = AgentActivityTool(
            callID: "late-call",
            name: "edit_file",
            owner: .worker
        )
        #expect(!store.advance(envelope, to: .verifying))
        #expect(!store.beginTool(lateTool, envelope: envelope))
        #expect(!store.finishTool(callID: "late-call", envelope: envelope))
        #expect(
            !store.begin(
                envelope: envelope,
                coordinator: testCoordinator,
                worker: testWorker
            )
        )
        #expect(store.current?.phase == .succeeded)
        #expect(store.current?.finalResult == result)
    }

    @Test("A stale tool completion does not clear the current invocation")
    func keepsNewerToolWhenOldCompletionArrives() throws {
        let store = AgentActivityStore()
        let envelope = try makeEnvelope()
        #expect(store.beginTestAttempt(envelope))
        #expect(store.advance(envelope, to: .delegating))
        #expect(store.advance(envelope, to: .workerRunning))
        let currentTool = AgentActivityTool(
            callID: "call-new",
            name: "grep",
            owner: .worker
        )
        #expect(store.beginTool(currentTool, envelope: envelope))

        #expect(!store.finishTool(callID: "call-old", envelope: envelope))
        #expect(store.current?.activeTool == currentTool)
    }

    @Test("Reset clears presentation and rejects late callbacks")
    func resetTombstonesCurrentAttempt() throws {
        let store = AgentActivityStore()
        let envelope = try makeEnvelope()
        #expect(store.beginTestAttempt(envelope))

        store.reset()

        #expect(store.current == nil)
        #expect(
            !store.begin(
                envelope: envelope,
                coordinator: testCoordinator,
                worker: testWorker
            )
        )
        #expect(!store.advance(envelope, to: .delegating))
        #expect(store.current == nil)
    }

    private var allPhases: [AgentActivityPhase] {
        [
            .preparing,
            .delegating,
            .workerRunning,
            .verifying,
            .succeeded,
            .failed,
            .cancelled
        ]
    }

    private var testCoordinator: AgentActivityAgent {
        .init(modelName: "DeepSeek", role: .powerfulCoordinator)
    }

    private var testWorker: AgentActivityAgent {
        .init(modelName: "Local Llama", role: .codingWorker)
    }

    private func makeEnvelope(
        attemptID: String = "attempt-1"
    ) throws -> AgentTaskEnvelope {
        try AgentTaskEnvelope(
            taskID: "task-activity",
            attemptID: attemptID,
            goal: "Implement the focused change.",
            acceptanceCriteria: ["The focused test passes."]
        )
    }

    private func makeResult(
        envelope: AgentTaskEnvelope,
        outcome: AgentTaskOutcome
    ) throws -> AgentTaskResult {
        let verification: AgentVerificationResult
        let failureReason: AgentTaskFailureReason?
        switch outcome {
        case .verified:
            verification = .init(
                status: .passed,
                receiptID: "verification-receipt"
            )
            failureReason = nil
        case .failed:
            verification = .init(status: .notRequested)
            failureReason = .workerFailed
        case .cancelled:
            verification = .init(status: .cancelled)
            failureReason = .cancelled
        case .completed:
            verification = .init(status: .notRequested)
            failureReason = nil
        }

        return try AgentTaskResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            outcome: outcome,
            technicalSummary: "Terminal test result.",
            receiptIDs: verification.receiptID.map { [$0] } ?? [],
            verification: verification,
            failureReason: failureReason
        )
    }
}

private nonisolated struct PhaseTransition: Hashable {
    let from: AgentActivityPhase
    let to: AgentActivityPhase
}

private extension AgentActivityStore {
    @discardableResult
    func beginTestAttempt(_ envelope: AgentTaskEnvelope) -> Bool {
        begin(
            envelope: envelope,
            coordinator: .init(
                modelName: "DeepSeek",
                role: .powerfulCoordinator
            ),
            worker: .init(
                modelName: "Local Llama",
                role: .codingWorker
            )
        )
    }

    @discardableResult
    func advance(
        _ envelope: AgentTaskEnvelope,
        to phase: AgentActivityPhase
    ) -> Bool {
        advance(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            to: phase
        )
    }

    @discardableResult
    func beginTool(
        _ tool: AgentActivityTool,
        envelope: AgentTaskEnvelope
    ) -> Bool {
        beginTool(
            tool,
            taskID: envelope.taskID,
            attemptID: envelope.attemptID
        )
    }

    @discardableResult
    func finishTool(
        callID: String,
        envelope: AgentTaskEnvelope
    ) -> Bool {
        finishTool(
            callID: callID,
            taskID: envelope.taskID,
            attemptID: envelope.attemptID
        )
    }
}
