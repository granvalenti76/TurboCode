import Foundation

/// Transitional runtime owner for provider-neutral turn lifecycle state.
///
/// This first extraction remains MainActor-isolated because the existing
/// coordinator receives synchronous MainActor callbacks from the provider
/// adapters. It deliberately owns no provider session, tool execution, or
/// timeline state; those boundaries move only after the compatibility path is
/// covered. The service can therefore become an actor in a later slice without
/// changing the `TurnStateReducer` contract.
@MainActor
final class AgentRuntime {
    private var turnReducer = TurnStateReducer()
    private var quiescenceDepth = 0
    /// The concrete operation handle is runtime lifecycle state, not provider
    /// state. Keeping it here lets navigation cancel and await one operation
    /// without making the UI facade the owner of the response task.
    private var operationTask: Task<Void, Never>?
    private var operationTurnID: TurnID?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var snapshot: RuntimeSnapshot

    init(
        activeThreadID: String? = nil,
        backend: ModelBackend = .foundationApple
    ) {
        snapshot = RuntimeSnapshot(
            activeThreadID: activeThreadID,
            backend: backend
        )
    }

    var currentTurnState: TurnState? {
        snapshot.turn
    }

    var hasActiveOperation: Bool {
        operationTask != nil
    }

    func ownsOperation(_ turnID: TurnID) -> Bool {
        operationTurnID == turnID
    }

    /// Creates and owns one response or independent worker operation through
    /// settlement. Callers provide provider work but never retain its concrete
    /// task, so the UI facade cannot release ownership before cancellation has
    /// finished unwinding.
    @discardableResult
    func runOperation(
        turnID: TurnID,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) async -> Bool {
        guard operationTask == nil, !snapshot.isQuiescing else { return false }

        let task = Task { await operation() }
        operationTask = task
        operationTurnID = turnID
        await task.value
        finishOperation(for: turnID)
        return true
    }

    /// Cancels and awaits the owned task before reporting idle. Keeping both
    /// actions inside the runtime prevents navigation from installing a new
    /// context while provider cleanup still targets the previous thread.
    func cancelAndWaitForOperation() async {
        guard let task = operationTask else { return }
        let turnID = operationTurnID
        task.cancel()
        await task.value
        if let turnID {
            finishOperation(for: turnID)
        }
    }

    /// Suspends without polling until the current operation releases runtime
    /// ownership. Waiters are resumed together because idle is a state edge,
    /// not a consumable event owned by one caller.
    func waitUntilIdle() async {
        guard operationTask != nil else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    /// Requests cancellation for user-initiated stop without awaiting on the
    /// MainActor. Transition boundaries use `cancelAndWaitForOperation()` when
    /// they must prove quiescence before replacing the active context.
    func requestOperationCancellation() {
        operationTask?.cancel()
    }

    /// Releases the operation only when its owning turn settles. Resuming idle
    /// waiters here gives every caller the same post-settlement observation.
    private func finishOperation(for turnID: TurnID) {
        guard operationTurnID == turnID else { return }
        operationTask = nil
        operationTurnID = nil
        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Applies provider-neutral lifecycle and context commands. Provider work
    /// still settles outside this service, but every transition clears the
    /// previous turn before publishing the new runtime context.
    @discardableResult
    func apply(_ command: RuntimeCommand) -> Bool {
        switch command {
        case .submit(let request):
            // Backend adapters echo `.started` after the facade has admitted
            // the request. Treat the same TurnID as idempotent, but never let
            // a competing request replace live state.
            if let turn = snapshot.turn, turn.outcome == nil {
                return turn.id == request.id
            }
            begin(request)
            return true
        case .cancel(let turnID):
            return finish(
                with: .cancelled(reason: "Runtime transition cancelled the turn."),
                turnID: turnID
            )
        case .switchThread(let threadID):
            return resetContext(
                activeThreadID: threadID,
                backend: snapshot.backend
            )
        case .switchBackend(let selection):
            return resetContext(
                activeThreadID: snapshot.activeThreadID,
                backend: selection.backend
            )
        case .restore(let threadID):
            return resetContext(
                activeThreadID: threadID,
                backend: snapshot.backend
            )
        }
    }

    /// Reduces the provider-neutral event vocabulary into authoritative turn
    /// state. Presentation consumers may react to the same accepted event, but
    /// only this runtime decides whether its TurnID is current and whether the
    /// lifecycle transition is legal.
    @discardableResult
    func apply(_ event: AgentRuntimeEvent) -> Bool {
        switch event {
        case .started(let request):
            return apply(.submit(request))
        case .phaseChanged(let turnID, let phase, let date):
            return advance(to: phase, turnID: turnID, at: date)
        case .toolStarted(let call):
            return advance(
                to: .toolExecuting,
                turnID: call.turnID,
                at: call.startedAt
            )
        case .toolFinished(let result):
            return advance(
                to: .streaming,
                turnID: result.turnID,
                at: Date()
            )
        case .approvalRequested(let approval):
            return advance(
                to: .awaitingApproval,
                turnID: approval.turnID,
                at: approval.requestedAt
            )
        case .assistantTextChanged(let turnID, _),
             .reasoningTextChanged(let turnID, _),
             .usageUpdated(let turnID, _, _, _):
            // Content and usage remain projection data in 0.3.6. Ownership is
            // still checked here so a stale provider event is rejected before
            // any presentation store sees it.
            return owns(turnID)
        case .completed(let turnID, let outcome, let date):
            return finish(with: outcome, turnID: turnID, at: date)
        }
    }

    func begin(_ request: TurnRequest) {
        turnReducer.begin(request)
        publish(
            backend: request.backend,
            at: request.createdAt
        )
    }

    @discardableResult
    func advance(
        to phase: TurnPhase,
        turnID: TurnID,
        at date: Date = Date()
    ) -> Bool {
        guard turnReducer.advance(to: phase, turnID: turnID, at: date) else {
            return false
        }
        publish(at: date)
        return true
    }

    @discardableResult
    func finish(
        with outcome: TurnOutcome,
        turnID: TurnID,
        at date: Date = Date()
    ) -> Bool {
        guard turnReducer.finish(with: outcome, turnID: turnID, at: date) else {
            return false
        }
        publish(at: date)
        return true
    }

    func owns(_ turnID: TurnID) -> Bool {
        turnReducer.owns(turnID)
    }

    /// Begins a transition barrier. Nested navigation operations keep the
    /// runtime quiescing until the outermost operation has settled.
    func beginQuiescence() {
        quiescenceDepth += 1
        publish(isQuiescing: true)
    }

    /// Ends one transition barrier without reopening the runtime prematurely.
    func endQuiescence() {
        guard quiescenceDepth > 0 else { return }
        quiescenceDepth -= 1
        publish(isQuiescing: quiescenceDepth > 0)
    }

    private func publish(
        backend: ModelBackend? = nil,
        isQuiescing: Bool? = nil,
        at date: Date = Date()
    ) {
        snapshot = RuntimeSnapshot(
            activeThreadID: snapshot.activeThreadID,
            backend: backend ?? snapshot.backend,
            turn: turnReducer.state,
            isQuiescing: isQuiescing ?? snapshot.isQuiescing,
            updatedAt: date
        )
    }

    @discardableResult
    private func resetContext(
        activeThreadID: String?,
        backend: ModelBackend,
        at date: Date = Date()
    ) -> Bool {
        guard snapshot.turn?.outcome != nil || snapshot.turn == nil else {
            return false
        }
        turnReducer.reset()
        snapshot = RuntimeSnapshot(
            activeThreadID: activeThreadID,
            backend: backend,
            isQuiescing: snapshot.isQuiescing,
            updatedAt: date
        )
        return true
    }
}
