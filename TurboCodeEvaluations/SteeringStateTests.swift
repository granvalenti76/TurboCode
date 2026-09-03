import Foundation
import Testing
@testable import TurboCode

@Suite("Steering state")
struct SteeringStateTests {
    @Test("Queue assigns FIFO sequence and claims the complete pending prefix")
    func claimsFIFOQueue() {
        var state = SteeringState()
        let context = makeContext()
        let firstDate = Date(timeIntervalSince1970: 10)
        let first = state.enqueue(
            text: "First",
            context: context,
            id: SteeringRequestID(rawValue: "first"),
            queuedAt: firstDate
        )
        let second = state.enqueue(
            text: "Second",
            context: context,
            id: SteeringRequestID(rawValue: "second"),
            queuedAt: firstDate.addingTimeInterval(1)
        )

        #expect(first?.sequence == 1)
        #expect(second?.sequence == 2)
        let batch = state.claimBatch(
            for: context,
            intent: .automatic,
            id: SteeringDeliveryID(rawValue: "delivery"),
            claimedAt: firstDate.addingTimeInterval(2)
        )
        #expect(batch?.requestIDs.map(\.rawValue) == ["first", "second"])
        #expect(state.requests.allSatisfy { $0.state == .delivering })
        #expect(state.claimBatch(for: context, intent: .sendNow) == nil)
    }

    @Test("Acknowledgement is accepted only for the active claim")
    func acknowledgesOnlyMatchingClaim() {
        var state = SteeringState()
        let context = makeContext()
        _ = state.enqueue(text: "Inspect", context: context)
        let batch = state.claimBatch(for: context, intent: .sendNow)!
        let wrongReceipt = SteeringDeliveryReceipt(
            deliveryID: SteeringDeliveryID(rawValue: "wrong")
        )
        let rejectedAcknowledgement = state.acknowledge(
            batch,
            receipt: wrongReceipt
        )
        #expect(!rejectedAcknowledgement)
        #expect(state.requests.first?.state == .delivering)

        let receipt = SteeringDeliveryReceipt(deliveryID: batch.id)
        let acknowledged = state.acknowledge(batch, receipt: receipt)
        #expect(acknowledged)
        #expect(state.requests.first?.state == .delivered)
        #expect(state.requests.first?.receipt == receipt)
        #expect(state.activeDelivery == nil)
    }

    @Test("Uncertain delivery is not automatically retryable")
    func doesNotRetryUncertainDelivery() {
        var state = SteeringState()
        let context = makeContext()
        let request = state.enqueue(text: "Apply the constraint", context: context)!
        let batch = state.claimBatch(for: context, intent: .sendNow)!

        let markedUncertain = state.markUncertain(batch)
        #expect(markedUncertain)
        #expect(state.requests.first?.state == .uncertain)
        let resumed = state.resume(request.id, in: context)
        #expect(!resumed)
        #expect(state.claimBatch(for: context, intent: .sendNow) == nil)
    }

    @Test("Context generation pauses pending requests and rejects stale resumes")
    func advancesContextGeneration() {
        var state = SteeringState()
        let context = makeContext()
        let request = state.enqueue(text: "Keep this in the old chat", context: context)!

        let advanced = state.advanceContextGeneration()
        #expect(advanced)
        #expect(state.contextGeneration == 1)
        #expect(state.requests.first?.state == .paused)
        let resumed = state.resume(request.id, in: context)
        #expect(!resumed)
    }

    private func makeContext() -> SteeringContext {
        SteeringContext(
            conversationID: "conversation",
            originTurnID: TurnID(rawValue: "turn"),
            contextGeneration: 0,
            workspaceRoot: "/workspace",
            providerSelection: RuntimeBackendSelection(
                backend: .foundationApple,
                modelName: "configured-model"
            )
        )
    }
}
