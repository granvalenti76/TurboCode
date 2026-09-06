import Foundation

/// Actor-isolated owner of provider-neutral lifecycle and operation state.
///
/// The runtime contains no UI framework, observable state, provider adapter, or
/// persistence dependency. Consumers submit commands/events and receive complete
/// immutable snapshots through an async `Sendable` output port. Keeping the
/// lifecycle owner inside TurboCodeCore prevents application stores from
/// becoming a second authority for cancellation, settlement, or turn identity.
actor AgentRuntime {
    private var turnReducer = TurnStateReducer()
    private var quiescenceDepth = 0
    /// The actor retains the application operation through provider unwind.
    /// Presentation receives only `hasActiveOperation` in the snapshot.
    private var operationTask: Task<Void, Never>?
    private var operationTurnID: TurnID?
    private var operationKind: RuntimeOperationKind?
    /// Retained until the context changes so a completed `/task` cannot be
    /// mistaken for a conversational turn during the idle/release boundary.
    private var contextOperationKind: RuntimeOperationKind?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var steeringState = SteeringState()
    private var activeSteeringContext: SteeringContext?
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

    var activeOperationKind: RuntimeOperationKind? {
        operationKind
    }

    var steeringContextGeneration: UInt64 {
        steeringState.contextGeneration
    }

    var steeringSnapshot: SteeringQueueSnapshot {
        steeringState.snapshot
    }

    /// Returns the context identity captured for the active conversational
    /// turn. Callers cannot manufacture a valid generation from UI state.
    func steeringContext(for turnID: TurnID) -> SteeringContext? {
        guard activeSteeringContext?.originTurnID == turnID,
              snapshot.turn?.id == turnID,
              snapshot.turn != nil else {
            return nil
        }
        return activeSteeringContext
    }

    /// Admits and owns one response or independent worker operation. Detached
    /// execution prevents provider work from inheriting actor isolation; the
    /// actor retains only its task handle and terminal ownership protocol.
    @discardableResult
    func runOperation(
        turnID: TurnID,
        operationKind: RuntimeOperationKind = .conversational,
        operation: @escaping @Sendable () async -> Void,
        afterRelease: @escaping @Sendable () async -> Void = {}
    ) async -> Bool {
        guard operationTask == nil, !snapshot.isQuiescing else { return false }

        let task = Task.detached {
            await operation()
        }
        operationTask = task
        operationTurnID = turnID
        self.operationKind = operationKind
        contextOperationKind = operationKind
        await publish(hasActiveOperation: true)
        await task.value
        await finishOperation(for: turnID)
        await afterRelease()
        return true
    }

    /// Reserves the context role before an independent coordinator performs
    /// its first asynchronous setup step. This closes the admission gap
    /// between `.started` and the worker's retained operation handle.
    func reserveOperationKind(
        _ kind: RuntimeOperationKind,
        for turnID: TurnID
    ) {
        guard snapshot.turn?.id == turnID, snapshot.turn?.outcome == nil else {
            return
        }
        contextOperationKind = kind
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
        operationKind = nil
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
        activeSteeringContext = SteeringContext(
            conversationID: snapshot.activeThreadID,
            originTurnID: request.id,
            contextGeneration: steeringState.contextGeneration,
            workspaceRoot: request.workspaceRoot,
            providerSelection: RuntimeBackendSelection(
                backend: request.backend,
                modelName: request.modelName
            )
        )
        contextOperationKind = .conversational
        await publish(backend: request.backend, at: request.createdAt)
    }

    /// Atomically captures text only for the active conversational operation.
    /// Independent work may keep the composer editable, but it cannot receive
    /// steering input merely because it makes the facade report `busy`.
    func enqueueSteering(
        text: String,
        context: SteeringContext,
        id: SteeringRequestID = SteeringRequestID(),
        queuedAt: Date = Date()
    ) async -> SteeringEnqueueResult {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .rejected(.emptyText)
        }
        guard !snapshot.isQuiescing else {
            return .rejected(.quiescing)
        }
        guard let activeSteeringContext,
              activeSteeringContext == context,
              snapshot.turn?.id == context.originTurnID,
              (snapshot.turn?.outcome == nil
                || snapshot.turn?.outcome == .succeeded) else {
            return .rejected(.staleContext)
        }
        if contextOperationKind == .independent
            || (operationTask != nil && operationKind != .conversational) {
            return .rejected(.independentOperation)
        }
        guard let request = steeringState.enqueue(
            text: normalized,
            context: context,
            id: id,
            queuedAt: queuedAt
        ) else {
            return .rejected(.staleContext)
        }
        await publish()
        return .accepted(request)
    }

    /// Claims the pending FIFO batch while still inside the lifecycle owner.
    /// The continuation/provider adapter will settle this claim later.
    func claimSteeringBatch(
        for context: SteeringContext,
        intent: SteeringDeliveryIntent,
        id: SteeringDeliveryID = SteeringDeliveryID(),
        claimedAt: Date = Date()
    ) async -> SteeringDeliveryBatch? {
        guard activeSteeringContext == context,
              snapshot.turn?.id == context.originTurnID,
              (snapshot.turn?.outcome == nil
                || snapshot.turn?.outcome == .succeeded),
              !snapshot.isQuiescing else { return nil }
        let batch = steeringState.claimBatch(
            for: context,
            intent: intent,
            id: id,
            claimedAt: claimedAt
        )
        if batch != nil {
            await publish()
        }
        return batch
    }

    @discardableResult
    func acknowledgeSteering(
        _ batch: SteeringDeliveryBatch,
        receipt: SteeringDeliveryReceipt
    ) async -> Bool {
        let changed = steeringState.acknowledge(batch, receipt: receipt)
        if changed { await publish() }
        return changed
    }

    @discardableResult
    func failSteering(
        _ batch: SteeringDeliveryBatch,
        failure: TurnFailure
    ) async -> Bool {
        let changed = steeringState.fail(batch, failure: failure)
        if changed { await publish() }
        return changed
    }

    @discardableResult
    func markSteeringUncertain(
        _ batch: SteeringDeliveryBatch
    ) async -> Bool {
        let changed = steeringState.markUncertain(batch)
        if changed { await publish() }
        return changed
    }

    /// Stops accepting the current queue without claiming provider delivery.
    /// A batch already handed to a provider is marked uncertain because Stop
    /// cannot prove whether that transport accepted the input.
    @discardableResult
    func pauseSteering() async -> Bool {
        if let activeDelivery = steeringState.activeDelivery {
            let changed = steeringState.markUncertain(activeDelivery)
            if changed { await publish() }
            return changed
        }
        return await pausePendingSteering() > 0
    }

    func steeringRequests(
        for batch: SteeringDeliveryBatch
    ) -> [SteeringRequest] {
        steeringState.requests(for: batch)
    }

    func ownsSteeringDelivery(_ batch: SteeringDeliveryBatch) -> Bool {
        steeringState.activeDelivery == batch
    }

    @discardableResult
    func pausePendingSteering() async -> Int {
        let changed = steeringState.pausePending()
        if changed > 0 { await publish() }
        return changed
    }

    @discardableResult
    func removeSteering(_ id: SteeringRequestID) async -> Bool {
        let changed = steeringState.remove(id)
        if changed { await publish() }
        return changed
    }

    @discardableResult
    func resumeSteering(
        _ id: SteeringRequestID,
        in context: SteeringContext
    ) async -> Bool {
        guard activeSteeringContext == context else { return false }
        let changed = steeringState.resume(id, in: context)
        if changed { await publish() }
        return changed
    }

    /// Restores only durable queue metadata. In-flight delivery claims become
    /// uncertain at the process boundary and are never replayed automatically.
    func restoreSteering(_ snapshot: SteeringQueueSnapshot) async {
        guard operationTask == nil, steeringState.activeDelivery == nil else {
            return
        }
        steeringState = SteeringState(restoring: snapshot)
        await publish()
    }

    /// Explicitly binds a recoverable request to the currently active turn.
    /// This is the only path that can move restored work into a new context.
    @discardableResult
    func recoverSteering(_ id: SteeringRequestID) async -> Bool {
        guard let context = activeSteeringContext,
              snapshot.turn?.id == context.originTurnID,
              snapshot.turn?.outcome == nil else { return false }
        let changed = steeringState.recover(id, in: context)
        if changed { await publish() }
        return changed
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
            operationKind: operationKind,
            isQuiescing: isQuiescing ?? snapshot.isQuiescing,
            steering: steeringState.snapshot,
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
        guard steeringState.advanceContextGeneration() else { return false }
        turnReducer.reset()
        activeSteeringContext = nil
        contextOperationKind = nil
        snapshot = RuntimeSnapshot(
            activeThreadID: activeThreadID,
            backend: backend,
            hasActiveOperation: snapshot.hasActiveOperation,
            operationKind: operationKind,
            isQuiescing: snapshot.isQuiescing,
            steering: steeringState.snapshot,
            updatedAt: date
        )
        await snapshotChanged(snapshot)
        return true
    }
}
