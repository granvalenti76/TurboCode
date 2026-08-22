import Foundation
import Testing
@testable import TurboCode

@Suite("Runtime contracts")
struct RuntimeContractsTests {
    @Test("A turn accepts only the ordered lifecycle transitions")
    func validatesTurnTransitions() {
        let accepted = TurnPhase.accepted
        #expect(accepted.canTransition(to: .preparing))
        #expect(accepted.canTransition(to: .cancelled))
        #expect(!accepted.canTransition(to: .streaming))
        // Some providers request approval after returning a structured tool
        // output, so the runtime may observe streaming before the approval UI.
        #expect(TurnPhase.streaming.canTransition(to: .awaitingApproval))
        #expect(!TurnPhase.completed.canTransition(to: .preparing))
    }

    @Test("Turn state rejects stale or invalid terminal updates")
    func rejectsInvalidStateUpdates() {
        let start = Date(timeIntervalSince1970: 100)
        let state = TurnState(id: TurnID(rawValue: "turn-1"), startedAt: start)
        let preparing = state.transitioning(
            to: .preparing,
            at: Date(timeIntervalSince1970: 101)
        )
        #expect(preparing?.phase == .preparing)
        #expect(preparing?.transitioning(to: .completed, at: Date()) == nil)

        let failed = preparing?.finishing(
            with: .failed(
                TurnFailure(code: "provider", message: "Unavailable")
            ),
            at: Date(timeIntervalSince1970: 102)
        )
        #expect(failed?.phase == .failed)
        #expect(failed?.outcome != nil)
        #expect(failed?.finishing(with: .succeeded, at: Date()) == nil)
    }

    @Test("Runtime commands round-trip without provider request types")
    func runtimeCommandsRoundTrip() throws {
        let turnID = TurnID(rawValue: "command-turn")
        let request = TurnRequest(
            id: turnID,
            prompt: "Inspect the workspace",
            backend: .llamaServer,
            modelName: "configured-model",
            workspaceRoot: "/workspace",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let commands: [RuntimeCommand] = [
            .submit(request),
            .cancel(turnID: turnID),
            .switchThread(threadID: "thread-2"),
            .switchBackend(
                RuntimeBackendSelection(
                    backend: .foundationServe,
                    modelName: "configured-pcc"
                )
            ),
            .restore(threadID: "thread-3")
        ]

        let data = try JSONEncoder().encode(commands)
        let decoded = try JSONDecoder().decode([RuntimeCommand].self, from: data)

        #expect(decoded == commands)
    }

    @Test("Runtime snapshots retain lifecycle ownership without UI state")
    func runtimeSnapshotRoundTrips() throws {
        let start = Date(timeIntervalSince1970: 200)
        let turnID = TurnID(rawValue: "snapshot-turn")
        let turn = TurnState(
            id: turnID,
            phase: .toolExecuting,
            startedAt: start,
            updatedAt: Date(timeIntervalSince1970: 201)
        )
        let snapshot = RuntimeSnapshot(
            activeThreadID: "thread-1",
            backend: .codex,
            turn: turn,
            isQuiescing: true,
            updatedAt: Date(timeIntervalSince1970: 202)
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(RuntimeSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.turn?.id == turnID)
        #expect(decoded.isQuiescing)
    }

    @Test("Backend event delivery applies ordered backpressure")
    func backendEventsWaitForEarlierDelivery() async {
        let turnID = TurnID(rawValue: "ordered-event-turn")
        let request = TurnRequest(
            id: turnID,
            prompt: "Preserve event order",
            backend: .foundationApple,
            modelName: "test-model",
            workspaceRoot: "/workspace"
        )
        let recorder = RuntimeEventOrderRecorder()
        let gate = RuntimeEventDeliveryGate()
        let (firstDelivery, signal) = AsyncStream.makeStream(of: Void.self)
        let events = BackendSessionEvents { event in
            let count = await recorder.append(event.turnID)
            if count == 1 {
                signal.yield()
                await gate.waitUntilOpen()
            }
        }
        let producer = Task {
            await events.emit(.started(request))
            await events.emit(
                .completed(
                    turnID: turnID,
                    outcome: .succeeded,
                    at: Date()
                )
            )
        }
        var iterator = firstDelivery.makeAsyncIterator()

        _ = await iterator.next()
        #expect(await recorder.count == 1)

        await gate.open()
        await producer.value
        #expect(await recorder.count == 2)
        signal.finish()
    }

    @Test("The lifecycle reducer rejects stale and invalid callbacks")
    func reducesLifecycleWithoutProviderState() {
        let id = TurnID(rawValue: "reducer-turn")
        let request = TurnRequest(
            id: id,
            prompt: "Run the reducer",
            backend: .foundationApple,
            modelName: "test-model",
            workspaceRoot: "/workspace",
            createdAt: Date(timeIntervalSince1970: 300)
        )
        var reducer = TurnStateReducer()

        reducer.begin(request)
        let advanced = reducer.advance(
            to: .preparing,
            turnID: id,
            at: Date(timeIntervalSince1970: 301)
        )
        #expect(advanced)
        let staleAdvance = reducer.advance(
            to: .streaming,
            turnID: TurnID(rawValue: "stale-turn"),
            at: Date(timeIntervalSince1970: 302)
        )
        #expect(!staleAdvance)
        #expect(reducer.state?.phase == .preparing)
        let invalidFinish = reducer.finish(
            with: .succeeded,
            turnID: id,
            at: Date(timeIntervalSince1970: 303)
        )
        #expect(!invalidFinish)
        #expect(reducer.state?.outcome == nil)
        #expect(reducer.owns(id))
    }

    @Test("The lifecycle reducer stores one terminal outcome")
    func reducesTerminalOutcome() {
        let id = TurnID(rawValue: "terminal-turn")
        var reducer = TurnStateReducer(
            state: TurnState(
                id: id,
                phase: .settling,
                startedAt: Date(timeIntervalSince1970: 400),
                updatedAt: Date(timeIntervalSince1970: 401)
            )
        )

        let finished = reducer.finish(
            with: .succeeded,
            turnID: id,
            at: Date(timeIntervalSince1970: 402)
        )
        #expect(finished)
        #expect(reducer.state?.phase == .completed)
        #expect(!reducer.owns(id))
        let lateFinish = reducer.finish(
            with: .cancelled(reason: "late"),
            turnID: id,
            at: Date(timeIntervalSince1970: 403)
        )
        #expect(!lateFinish)
    }

    @Test("Runtime measurements clamp invalid values")
    func clampsMeasurements() {
        let usage = Usage(
            inputTokens: -10,
            cachedInputTokens: -3,
            outputTokens: 12
        )
        #expect(usage.inputTokens == 0)
        #expect(usage.cachedInputTokens == 0)
        #expect(usage.totalTokens == 12)

        let context = ContextUsage(usedTokens: -4, contextSize: 0)
        #expect(context.usedTokens == 0)
        #expect(context.contextSize == 1)
        #expect(context.fraction == 0)
    }

    @Test("Every normalized event exposes its owning turn")
    func exposesEventTurnID() {
        let id = TurnID(rawValue: "turn-2")
        let request = TurnRequest(
            id: id,
            prompt: "Inspect the project",
            backend: .foundationApple,
            modelName: "On-device",
            workspaceRoot: "/workspace"
        )
        let call = ToolCall(
            id: "call-1",
            turnID: id,
            name: "read_file"
        )

        #expect(AgentRuntimeEvent.started(request).turnID == id)
        #expect(AgentRuntimeEvent.toolStarted(call).turnID == id)
        #expect(
            AgentRuntimeEvent.completed(
                turnID: id,
                outcome: .succeeded,
                at: Date()
            ).turnID == id
        )
    }

    @Test("Worker envelopes preserve parent turn ownership without changing tool input")
    func preservesWorkerParentTurnOwnership() throws {
        let parent = TurnID(rawValue: "parent-turn")
        let envelope = try AgentTaskEnvelope(
            taskID: "task-1",
            attemptID: "attempt-1",
            goal: "Inspect the workspace.",
            acceptanceCriteria: ["Return a result."],
            parentTurnID: parent
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            AgentTaskEnvelope.self,
            from: data
        )

        #expect(decoded.parentTurnID == parent)
        #expect(decoded.goal == envelope.goal)
        #expect(decoded.mode == .coding)
    }

    @Test("Backend session results stay independent from provider transport")
    func keepsBackendSessionResultProviderNeutral() throws {
        let result = BackendSessionResult(
            assistantText: "Done.",
            reasoningText: "Inspected the workspace.",
            outcome: .succeeded
        )

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(
            BackendSessionResult.self,
            from: encoded
        )

        #expect(decoded == result)
    }

    @Test("Independent task completions reject stale and cancelled results")
    func guardsIndependentTaskCompletion() {
        let active = TurnID(rawValue: "active")
        let stale = TurnID(rawValue: "stale")

        #expect(
            TurnCompletionPolicy.accepts(
                turnID: active,
                activeTurnID: active,
                isCancelled: false
            )
        )
        #expect(
            !TurnCompletionPolicy.accepts(
                turnID: stale,
                activeTurnID: active,
                isCancelled: false
            )
        )
        #expect(
            !TurnCompletionPolicy.accepts(
                turnID: active,
                activeTurnID: active,
                isCancelled: true
            )
        )
    }

    @Test("Independent task terminal mapping preserves failure detail")
    func mapsIndependentTaskFailureForRuntimeAndTimeline() throws {
        let result = try AgentTaskResult(
            taskID: "task-failed",
            attemptID: "attempt-1",
            outcome: .failed,
            technicalSummary: "The requested edit could not be completed.",
            failureReason: .invalidResult,
            failureDetail: "The worker returned an invalid payload.",
            unresolvedWork: ["Retry with a valid worker response."]
        )

        let rendered = IndependentTaskCoordinator.render(result)
        #expect(rendered.contains("Status: `failed`"))
        #expect(rendered.contains("The worker returned an invalid payload."))
        #expect(rendered.contains("Retry with a valid worker response."))

        guard case .failed(let failure) =
                IndependentTaskCoordinator.runtimeOutcome(for: result) else {
            Issue.record("Expected a failed runtime outcome")
            return
        }
        #expect(failure.code == AgentTaskFailureReason.invalidResult.rawValue)
        #expect(failure.message == result.failureDetail)
    }
}

private actor RuntimeEventOrderRecorder {
    private var turnIDs: [TurnID] = []

    var count: Int { turnIDs.count }

    func append(_ turnID: TurnID) -> Int {
        turnIDs.append(turnID)
        return turnIDs.count
    }
}

/// A latched gate avoids a timing-dependent test: opening before the waiter is
/// installed remains observable and still releases the first event delivery.
private actor RuntimeEventDeliveryGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func waitUntilOpen() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
