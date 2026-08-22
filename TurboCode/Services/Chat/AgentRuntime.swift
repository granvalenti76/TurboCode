import Foundation

/// Actor-isolated owner of provider-neutral lifecycle and operation state.
///
/// The runtime contains no UI framework, observable state, provider adapter, or
/// persistence dependency. Consumers submit commands/events and receive complete
/// immutable snapshots through an async `Sendable` output port, which keeps this
/// boundary suitable for a future `TurboCodeCore` package.
actor AgentRuntime {
    private var turnReducer = TurnStateReducer()
    private var quiescenceDepth = 0
    /// The actor retains the application operation through provider unwind.
    /// Presentation receives only `hasActiveOperation` in the snapshot.
    private var operationTask: Task<Void, Never>?
    private var operationTurnID: TurnID?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var snapshot: RuntimeSnapshot
    private let snapshotChanged: @Sendable (RuntimeSnapshot) async -> Void

    init(
        activeThreadID: String? = nil,
        backend: ModelBackend = .foundationApple,
        snapshotChanged: @escaping @Sendable (
            RuntimeSnapshot
        ) async -> Void = { _ in }
    ) {
        snapshot = RuntimeSnapshot(
            activeThreadID: activeThreadID,
            backend: backend
        )
        self.snapshotChanged = snapshotChanged
    }

    var currentTurnState: TurnState? {
        snapshot.turn
    }

    var hasActiveOperation: Bool {
        snapshot.hasActiveOperation
    }

    func ownsOperation(_ turnID: TurnID) -> Bool {
        operationTurnID == turnID
    }

    /// Admits and owns one response or independent worker operation. Detached
    /// execution prevents provider work from inheriting actor isolation; the
    /// actor retains only its task handle and terminal ownership protocol.
    @discardableResult
    func runOperation(
        turnID: TurnID,
        operation: @escaping @Sendable () async -> Void,
        afterRelease: @escaping @Sendable () async -> Void = {}
    ) async -> Bool {
        guard operationTask == nil, !snapshot.isQuiescing else { return false }

        let task = Task.detached {
            await operation()
        }
        operationTask = task
        operationTurnID = turnID
        await publish(hasActiveOperation: true)
        await task.value
        await finishOperation(for: turnID)
        await afterRelease()
        return true
    }

    /// Cancels and awaits the owned task before publishing idle. Context
    /// transitions can therefore prove the old provider has unwound.
    func cancelAndWaitForOperation() async {
        guard let task = operationTask else { return }
        let turnID = operationTurnID
        task.cancel()
        await task.value
        if let turnID {
            await finishOperation(for: turnID)
        }
    }

    /// Suspends without polling until the active operation releases ownership.
    func waitUntilIdle() async {
        guard operationTask != nil else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    func requestOperationCancellation() {
        operationTask?.cancel()
    }

    /// Only the owning turn may release the task. Snapshot publication precedes
    /// waiter resumption, so every awakened consumer observes the idle edge.
    private func finishOperation(for turnID: TurnID) async {
        guard operationTurnID == turnID else { return }
        operationTask = nil
        operationTurnID = nil
        await publish(hasActiveOperation: false)
        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    @discardableResult
    func apply(_ command: RuntimeCommand) async -> Bool {
        switch command {
        case .submit(let request):
            // Provider adapters echo `.started` after application admission.
            // The same TurnID is idempotent; a competing live turn is rejected.
            if let turn = snapshot.turn, turn.outcome == nil {
                return turn.id == request.id
            }
            await begin(request)
            return true
        case .cancel(let turnID):
            return await finish(
                with: .cancelled(
                    reason: "Runtime transition cancelled the turn."
                ),
                turnID: turnID
            )
        case .switchThread(let threadID):
            return await resetContext(
                activeThreadID: threadID,
                backend: snapshot.backend
            )
        case .switchBackend(let selection):
            return await resetContext(
                activeThreadID: snapshot.activeThreadID,
                backend: selection.backend
            )
        case .restore(let threadID):
            return await resetContext(
                activeThreadID: threadID,
                backend: snapshot.backend
            )
        }
    }

    /// Reduces normalized provider events serially inside the actor. Awaited
    /// backend ports guarantee completion cannot overtake an earlier event.
    @discardableResult
    func apply(_ event: AgentRuntimeEvent) async -> Bool {
        switch event {
        case .started(let request):
            return await apply(.submit(request))
        case .phaseChanged(let turnID, let phase, let date):
            return await advance(to: phase, turnID: turnID, at: date)
        case .toolStarted(let call):
            return await advance(
                to: .toolExecuting,
                turnID: call.turnID,
                at: call.startedAt
            )
        case .toolFinished(let result):
            return await advance(
                to: .streaming,
                turnID: result.turnID,
                at: Date()
            )
        case .approvalRequested(let approval):
            return await advance(
                to: .awaitingApproval,
                turnID: approval.turnID,
                at: approval.requestedAt
            )
        case .assistantTextChanged(let turnID, _),
             .reasoningTextChanged(let turnID, _),
             .usageUpdated(let turnID, _, _, _):
            // Content is projection data; the core still rejects stale IDs
            // before presentation is allowed to mutate.
            return owns(turnID)
        case .completed(let turnID, let outcome, let date):
            return await finish(with: outcome, turnID: turnID, at: date)
        }
    }

    func begin(_ request: TurnRequest) async {
        turnReducer.begin(request)
        await publish(backend: request.backend, at: request.createdAt)
    }

    @discardableResult
    func advance(
        to phase: TurnPhase,
        turnID: TurnID,
        at date: Date = Date()
    ) async -> Bool {
        guard turnReducer.advance(to: phase, turnID: turnID, at: date) else {
            return false
        }
        await publish(at: date)
        return true
    }

    @discardableResult
    func finish(
        with outcome: TurnOutcome,
        turnID: TurnID,
        at date: Date = Date()
    ) async -> Bool {
        guard turnReducer.finish(with: outcome, turnID: turnID, at: date) else {
            return false
        }
        await publish(at: date)
        return true
    }

    func owns(_ turnID: TurnID) -> Bool {
        turnReducer.owns(turnID)
    }

    func beginQuiescence() async {
        quiescenceDepth += 1
        await publish(isQuiescing: true)
    }

    func endQuiescence() async {
        guard quiescenceDepth > 0 else { return }
        quiescenceDepth -= 1
        await publish(isQuiescing: quiescenceDepth > 0)
    }

    private func publish(
        backend: ModelBackend? = nil,
        isQuiescing: Bool? = nil,
        hasActiveOperation: Bool? = nil,
        at date: Date = Date()
    ) async {
        snapshot = RuntimeSnapshot(
            activeThreadID: snapshot.activeThreadID,
            backend: backend ?? snapshot.backend,
            turn: turnReducer.state,
            hasActiveOperation: hasActiveOperation
                ?? snapshot.hasActiveOperation,
            isQuiescing: isQuiescing ?? snapshot.isQuiescing,
            updatedAt: date
        )
        await snapshotChanged(snapshot)
    }

    @discardableResult
    private func resetContext(
        activeThreadID: String?,
        backend: ModelBackend,
        at date: Date = Date()
    ) async -> Bool {
        guard snapshot.turn?.outcome != nil || snapshot.turn == nil else {
            return false
        }
        turnReducer.reset()
        snapshot = RuntimeSnapshot(
            activeThreadID: activeThreadID,
            backend: backend,
            hasActiveOperation: snapshot.hasActiveOperation,
            isQuiescing: snapshot.isQuiescing,
            updatedAt: date
        )
        await snapshotChanged(snapshot)
        return true
    }
}
