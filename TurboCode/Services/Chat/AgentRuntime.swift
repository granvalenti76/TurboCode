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
    private(set) var operationTurnID: TurnID?
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

    func registerOperation(
        _ task: Task<Void, Never>,
        turnID: TurnID
    ) {
        operationTask = task
        operationTurnID = turnID
    }

    func ownsOperation(_ turnID: TurnID) -> Bool {
        operationTurnID == turnID
    }

    /// Requests cancellation but keeps ownership until the caller has awaited
    /// the task. This prevents a replacement operation from being admitted
    /// while the previous provider or worker is still unwinding.
    func cancelOperation() -> Task<Void, Never>? {
        operationTask?.cancel()
        return operationTask
    }

    /// Releases the operation handle only when its owning turn has settled.
    func finishOperation(for turnID: TurnID) {
        guard operationTurnID == turnID else { return }
        operationTask = nil
        operationTurnID = nil
    }

    /// Applies provider-neutral lifecycle and context commands. Provider work
    /// still settles outside this service, but every transition clears the
    /// previous turn before publishing the new runtime context.
    @discardableResult
    func apply(_ command: RuntimeCommand) -> Bool {
        switch command {
        case .submit(let request):
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
