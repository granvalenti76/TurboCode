import Foundation

/// Pure FIFO state machine for steering requests.
///
/// This type intentionally owns no tasks or provider handles. `AgentRuntime`
/// is the sole caller that serializes its mutations with operation release,
/// context transitions, and cancellation.
nonisolated struct SteeringState: Codable, Hashable, Sendable {
    private(set) var contextGeneration: UInt64
    private(set) var requests: [SteeringRequest]
    private(set) var activeDelivery: SteeringDeliveryBatch?
    private var nextSequence: Int

    init(
        contextGeneration: UInt64 = 0,
        requests: [SteeringRequest] = [],
        activeDelivery: SteeringDeliveryBatch? = nil,
        nextSequence: Int? = nil
    ) {
        self.contextGeneration = contextGeneration
        self.requests = requests
        self.activeDelivery = activeDelivery
        self.nextSequence = nextSequence
            ?? ((requests.map(\.sequence).max() ?? 0) + 1)
    }

    var snapshot: SteeringQueueSnapshot {
        SteeringQueueSnapshot(
            contextGeneration: contextGeneration,
            requests: requests,
            activeDelivery: activeDelivery
        )
    }

    init(restoring snapshot: SteeringQueueSnapshot) {
        self.contextGeneration = snapshot.contextGeneration
        self.requests = snapshot.requests.map { request in
            var restored = request
            if restored.state == .delivering {
                restored.state = .uncertain
                restored.failure = TurnFailure(
                    code: "steering.delivery_uncertain",
                    message: "The previous process may have delivered this request.",
                    isRecoverable: true
                )
            }
            restored.deliveryID = nil
            restored.receipt = nil
            return restored
        }
        self.activeDelivery = nil
        self.nextSequence = (requests.map(\.sequence).max() ?? 0) + 1
    }

    /// Captures a non-empty request and assigns its FIFO sequence atomically.
    mutating func enqueue(
        text: String,
        context: SteeringContext,
        id: SteeringRequestID = SteeringRequestID(),
        queuedAt: Date = Date()
    ) -> SteeringRequest? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              context.contextGeneration == contextGeneration else {
            return nil
        }

        let request = SteeringRequest(
            id: id,
            sequence: nextSequence,
            context: context,
            text: normalized,
            queuedAt: queuedAt
        )
        nextSequence += 1
        requests.append(request)
        return request
    }

    /// Claims every currently queued request for the same context in sequence
    /// order. Claiming is the only operation that can move requests to
    /// `delivering`, so automatic and manual delivery cannot double-consume.
    mutating func claimBatch(
        for context: SteeringContext,
        intent: SteeringDeliveryIntent,
        id: SteeringDeliveryID = SteeringDeliveryID(),
        claimedAt: Date = Date()
    ) -> SteeringDeliveryBatch? {
        guard activeDelivery == nil,
              context.contextGeneration == contextGeneration else {
            return nil
        }

        let requestIDs = requests
            .filter {
                $0.state == .queued && $0.context == context
            }
            .sorted { $0.sequence < $1.sequence }
            .map(\.id)
        guard !requestIDs.isEmpty else { return nil }

        let batch = SteeringDeliveryBatch(
            id: id,
            requestIDs: requestIDs,
            context: context,
            intent: intent,
            claimedAt: claimedAt
        )
        for index in requests.indices
        where requestIDs.contains(requests[index].id) {
            requests[index].state = .delivering
            requests[index].deliveryID = id
            requests[index].receipt = nil
            requests[index].failure = nil
            requests[index].version += 1
        }
        activeDelivery = batch
        return batch
    }

    /// Commits a provider acceptance for exactly the currently claimed batch.
    mutating func acknowledge(
        _ batch: SteeringDeliveryBatch,
        receipt: SteeringDeliveryReceipt
    ) -> Bool {
        guard activeDelivery == batch,
              receipt.deliveryID == batch.id,
              requestsFor(batch).allSatisfy({ $0.state == .delivering }) else {
            return false
        }

        transition(
            batch,
            to: .delivered,
            receipt: receipt,
            failure: nil
        )
        activeDelivery = nil
        return true
    }

    /// Records a certain delivery rejection. The text remains available for
    /// explicit retry after validation; no automatic retry is implied.
    mutating func fail(
        _ batch: SteeringDeliveryBatch,
        failure: TurnFailure
    ) -> Bool {
        guard activeDelivery == batch,
              requestsFor(batch).allSatisfy({ $0.state == .delivering }) else {
            return false
        }

        transition(
            batch,
            to: .failed,
            receipt: nil,
            failure: failure
        )
        activeDelivery = nil
        return true
    }

    /// Records an uncertain transport result. Uncertain requests are never
    /// retried by this state machine because a duplicate provider submission
    /// could repeat workspace effects.
    mutating func markUncertain(_ batch: SteeringDeliveryBatch) -> Bool {
        guard activeDelivery == batch,
              requestsFor(batch).allSatisfy({ $0.state == .delivering }) else {
            return false
        }

        transition(
            batch,
            to: .uncertain,
            receipt: nil,
            failure: TurnFailure(
                code: "steering.delivery_uncertain",
                message: "The provider may have accepted this steering request.",
                isRecoverable: true
            )
        )
        activeDelivery = nil
        return true
    }

    /// Pauses requests that have not been claimed. A claimed delivery must be
    /// settled as delivered, failed, or uncertain by its owner first.
    mutating func pausePending() -> Int {
        var changed = 0
        for index in requests.indices where requests[index].state == .queued {
            requests[index].state = .paused
            requests[index].version += 1
            changed += 1
        }
        return changed
    }

    /// Removes only requests that have not been accepted by a provider.
    mutating func remove(_ id: SteeringRequestID) -> Bool {
        guard let index = requests.firstIndex(where: { $0.id == id }),
              [.queued, .paused, .failed].contains(requests[index].state) else {
            return false
        }
        requests[index].state = .removed
        requests[index].version += 1
        return true
    }

    /// Explicitly resumes a recoverable request after its context has been
    /// validated by the runtime owner.
    mutating func resume(
        _ id: SteeringRequestID,
        in context: SteeringContext
    ) -> Bool {
        guard context.contextGeneration == contextGeneration,
              let index = requests.firstIndex(where: { $0.id == id }),
              requests[index].context == context,
              [.paused, .failed].contains(requests[index].state) else {
            return false
        }
        requests[index].state = .queued
        requests[index].deliveryID = nil
        requests[index].receipt = nil
        requests[index].failure = nil
        requests[index].version += 1
        return true
    }

    /// Rebinds a paused request to a newly admitted conversational turn. This
    /// is an explicit recovery action; restored text never follows a new turn
    /// automatically across a context generation boundary.
    mutating func recover(
        _ id: SteeringRequestID,
        in context: SteeringContext
    ) -> Bool {
        guard context.contextGeneration == contextGeneration,
              let index = requests.firstIndex(where: { $0.id == id }),
              requests[index].state == .paused else {
            return false
        }
        requests[index].context = context
        requests[index].state = .queued
        requests[index].failure = nil
        requests[index].deliveryID = nil
        requests[index].receipt = nil
        requests[index].version += 1
        return true
    }

    /// Replaces the runtime context generation and pauses all unclaimed work.
    /// Delivery in progress blocks the transition so the caller cannot make a
    /// stale provider acknowledgement look current.
    mutating func advanceContextGeneration() -> Bool {
        guard activeDelivery == nil else { return false }
        contextGeneration &+= 1
        for index in requests.indices
        where [.queued, .failed].contains(requests[index].state) {
            requests[index].state = .paused
            requests[index].version += 1
        }
        return true
    }

    func requests(for batch: SteeringDeliveryBatch) -> [SteeringRequest] {
        batch.requestIDs.compactMap { id in
            requests.first(where: { $0.id == id })
        }
    }

    private func requestsFor(
        _ batch: SteeringDeliveryBatch
    ) -> [SteeringRequest] {
        batch.requestIDs.compactMap { id in
            requests.first(where: { $0.id == id })
        }
    }

    private mutating func transition(
        _ batch: SteeringDeliveryBatch,
        to state: SteeringRequestState,
        receipt: SteeringDeliveryReceipt?,
        failure: TurnFailure?
    ) {
        for index in requests.indices
        where batch.requestIDs.contains(requests[index].id) {
            requests[index].state = state
            requests[index].receipt = receipt
            requests[index].failure = failure
            requests[index].version += 1
        }
    }
}
