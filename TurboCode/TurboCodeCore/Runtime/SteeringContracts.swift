import Foundation

/// Identifies the kind of work currently owned by `AgentRuntime`.
///
/// Steering is meaningful only for a conversational operation. Keeping this
/// value in the runtime projection prevents `busy` from becoming an unsafe
/// proxy for steerability when an independent `/task` worker is running.
nonisolated enum RuntimeOperationKind: String, Codable, Hashable, Sendable {
    case conversational
    case independent
}

/// Stable identity for one locally captured steering request.
nonisolated struct SteeringRequestID: Codable, Hashable, Sendable,
    CustomStringConvertible {
    let rawValue: String

    init() {
        self.init(rawValue: UUID().uuidString)
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

/// Stable identity for one provider delivery attempt.
nonisolated struct SteeringDeliveryID: Codable, Hashable, Sendable,
    CustomStringConvertible {
    let rawValue: String

    init() {
        self.init(rawValue: UUID().uuidString)
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

/// Runtime-owned context captured when a conversational turn is admitted.
///
/// Generation is incremented when the conversation context is replaced. A
/// request with an old generation may remain visible for recovery, but it can
/// never be delivered into the new conversation implicitly.
nonisolated struct SteeringContext: Codable, Hashable, Sendable {
    let conversationID: String?
    let originTurnID: TurnID
    let contextGeneration: UInt64
    let workspaceRoot: String
    let providerSelection: RuntimeBackendSelection

    init(
        conversationID: String?,
        originTurnID: TurnID,
        contextGeneration: UInt64,
        workspaceRoot: String,
        providerSelection: RuntimeBackendSelection
    ) {
        self.conversationID = conversationID
        self.originTurnID = originTurnID
        self.contextGeneration = contextGeneration
        self.workspaceRoot = workspaceRoot
        self.providerSelection = providerSelection
    }
}

/// Lifecycle state of a locally captured request.
nonisolated enum SteeringRequestState: String, Codable, Hashable, Sendable {
    case queued
    case delivering
    case delivered
    case failed
    case uncertain
    case paused
    case removed
}

/// Whether a claimed batch was released automatically or by an explicit user
/// action. Both paths use the same claim operation and therefore cannot
/// deliver the same request twice.
nonisolated enum SteeringDeliveryIntent: String, Codable, Hashable, Sendable {
    case automatic
    case sendNow
}

/// Provider-neutral evidence that the input was accepted for delivery.
///
/// Acceptance is deliberately weaker than semantic adoption by the model. The
/// receipt is therefore stored separately from the request text and state.
nonisolated struct SteeringDeliveryReceipt: Codable, Hashable, Sendable {
    let deliveryID: SteeringDeliveryID
    let acceptedAt: Date
    let providerTurnID: String?

    init(
        deliveryID: SteeringDeliveryID,
        acceptedAt: Date = Date(),
        providerTurnID: String? = nil
    ) {
        self.deliveryID = deliveryID
        self.acceptedAt = acceptedAt
        self.providerTurnID = providerTurnID
    }
}

/// Correlates one delivered user block with its immutable queue receipt.
/// Pending requests intentionally have no timeline representation.
nonisolated struct SteeringDeliveryMetadata: Codable, Hashable, Sendable {
    let requestIDs: [SteeringRequestID]
    let deliveryID: SteeringDeliveryID
    let providerTurnID: String?

    init(
        requestIDs: [SteeringRequestID],
        deliveryID: SteeringDeliveryID,
        providerTurnID: String?
    ) {
        self.requestIDs = requestIDs
        self.deliveryID = deliveryID
        self.providerTurnID = providerTurnID
    }
}

/// A steering request retained by the runtime until its delivery outcome is
/// known. `version` changes on every state transition so persistence and UI
/// code can reject stale edits without comparing user text.
nonisolated struct SteeringRequest: Codable, Hashable, Sendable, Identifiable {
    let id: SteeringRequestID
    let sequence: Int
    var context: SteeringContext
    let text: String
    let queuedAt: Date
    var version: Int
    var state: SteeringRequestState
    var deliveryID: SteeringDeliveryID?
    var receipt: SteeringDeliveryReceipt?
    var failure: TurnFailure?

    init(
        id: SteeringRequestID = SteeringRequestID(),
        sequence: Int,
        context: SteeringContext,
        text: String,
        queuedAt: Date = Date(),
        version: Int = 1,
        state: SteeringRequestState = .queued,
        deliveryID: SteeringDeliveryID? = nil,
        receipt: SteeringDeliveryReceipt? = nil,
        failure: TurnFailure? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.context = context
        self.text = text
        self.queuedAt = queuedAt
        self.version = version
        self.state = state
        self.deliveryID = deliveryID
        self.receipt = receipt
        self.failure = failure
    }
}

/// An immutable claim over a FIFO prefix of requests.
nonisolated struct SteeringDeliveryBatch: Codable, Hashable, Sendable {
    let id: SteeringDeliveryID
    let requestIDs: [SteeringRequestID]
    let context: SteeringContext
    let intent: SteeringDeliveryIntent
    let claimedAt: Date

    init(
        id: SteeringDeliveryID,
        requestIDs: [SteeringRequestID],
        context: SteeringContext,
        intent: SteeringDeliveryIntent,
        claimedAt: Date
    ) {
        self.id = id
        self.requestIDs = requestIDs
        self.context = context
        self.intent = intent
        self.claimedAt = claimedAt
    }
}

/// The value-only queue projection exposed to stores and views.
nonisolated public struct SteeringQueueSnapshot: Codable, Hashable, Sendable {
    let contextGeneration: UInt64
    let requests: [SteeringRequest]
    let activeDelivery: SteeringDeliveryBatch?

    public static let empty = Self(
        contextGeneration: 0,
        requests: [],
        activeDelivery: nil
    )

    init(
        contextGeneration: UInt64,
        requests: [SteeringRequest],
        activeDelivery: SteeringDeliveryBatch?
    ) {
        self.contextGeneration = contextGeneration
        self.requests = requests
        self.activeDelivery = activeDelivery
    }
}

/// Result of local enqueue admission. A successful result means the runtime
/// acquired the text and its context identity; it does not claim provider
/// delivery or semantic adoption.
nonisolated enum SteeringEnqueueResult: Sendable, Equatable {
    case accepted(SteeringRequest)
    case rejected(SteeringEnqueueRejection)
}

nonisolated enum SteeringEnqueueRejection: String, Sendable, Equatable {
    case emptyText
    case noActiveConversation
    case independentOperation
    case staleContext
    case quiescing
}
