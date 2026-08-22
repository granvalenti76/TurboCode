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
}
