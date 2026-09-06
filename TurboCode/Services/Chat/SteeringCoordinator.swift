import Foundation

/// Application coordinator for steering commands and delivery claims.
///
/// The queue remains exclusively owned by `AgentRuntime`; this type only
/// translates UI intent into runtime commands and invokes the continuation
/// port supplied by `MessageSendCoordinator`. That separation keeps provider
/// sessions and scheduling out of SwiftUI while avoiding a second queue.
@MainActor
final class SteeringCoordinator {
    nonisolated enum DeliveryResult: Sendable {
        case accepted(providerTurnID: String?)
        case failed(TurnFailure)
        case uncertain
    }

    private let runtime: AgentRuntime
    private let llmRuntime: LLMRuntime
    private let interrupt: @MainActor @Sendable (TurnID) async -> Void
    private let prepareNativeDelivery: @MainActor @Sendable (
        TurnID,
        String,
        SteeringDeliveryMetadata,
        String
    ) -> Bool
    private let persist: @MainActor @Sendable () async -> Void
    private var deliveryHandler: (@MainActor @Sendable (
        SteeringDeliveryBatch,
        [SteeringRequest]
    ) async -> DeliveryResult)?

    init(
        runtime: AgentRuntime,
        llmRuntime: LLMRuntime,
        interrupt: @escaping @MainActor @Sendable (TurnID) async -> Void,
        prepareNativeDelivery: @escaping @MainActor @Sendable (
            TurnID,
            String,
            SteeringDeliveryMetadata,
            String
        ) -> Bool = { _, _, _, _ in false },
        persist: @escaping @MainActor @Sendable () async -> Void = {},
        deliveryHandler: (@MainActor @Sendable (
            SteeringDeliveryBatch,
            [SteeringRequest]
        ) async -> DeliveryResult)? = nil
    ) {
        self.runtime = runtime
        self.llmRuntime = llmRuntime
        self.interrupt = interrupt
        self.prepareNativeDelivery = prepareNativeDelivery
        self.persist = persist
        self.deliveryHandler = deliveryHandler
    }

    /// Installs the continuation port after the composition root has created
    /// `MessageSendCoordinator`; no coordinator owns provider execution here.
    func setDeliveryHandler(
        _ handler: @escaping @MainActor @Sendable (
            SteeringDeliveryBatch,
            [SteeringRequest]
        ) async -> DeliveryResult
    ) {
        deliveryHandler = handler
    }

    func enqueue(text: String) async -> SteeringEnqueueResult {
        guard let turnID = await runtime.currentTurnState?.id,
              let context = await runtime.steeringContext(for: turnID) else {
            return .rejected(.noActiveConversation)
        }
        let result = await runtime.enqueueSteering(text: text, context: context)
        if case .accepted = result {
            await persist()
        }
        return result
    }

    func pause() async {
        _ = await runtime.pauseSteering()
        await persist()
    }

    /// Sends the current FIFO batch immediately. For native backends this
    /// requests cooperative interruption and waits for the real runtime unwind
    /// before the continuation handler may start a second run.
    func sendNow() async {
        guard let turnID = await runtime.currentTurnState?.id,
              let context = await runtime.steeringContext(for: turnID),
              let batch = await runtime.claimSteeringBatch(
                  for: context,
                  intent: .sendNow
              ) else { return }
        if context.providerSelection.backend == .codex,
           await runtime.hasActiveOperation {
            let requests = await runtime.steeringRequests(for: batch)
            let input = Self.prompt(for: requests)
            let text = Self.displayText(for: requests)
            _ = prepareNativeDelivery(
                turnID,
                text,
                SteeringDeliveryMetadata(
                    requestIDs: batch.requestIDs,
                    deliveryID: batch.id,
                    providerTurnID: nil
                ),
                context.providerSelection.modelName ?? "Codex"
            )
            switch await llmRuntime.steer(turnID: turnID, input: input) {
            case .accepted(let providerTurnID):
                _ = await runtime.acknowledgeSteering(
                    batch,
                    receipt: SteeringDeliveryReceipt(
                        deliveryID: batch.id,
                        providerTurnID: providerTurnID
                    )
                )
            case .failed(let failure):
                _ = await runtime.failSteering(batch, failure: failure)
            case .uncertain:
                _ = await runtime.markSteeringUncertain(batch)
            case .unsupported:
                _ = await runtime.failSteering(
                    batch,
                    failure: TurnFailure(
                        code: "steering.unsupported",
                        message: "This Codex runtime does not support turn steering.",
                        isRecoverable: true
                    )
                )
            }
            await persist()
            return
        }
        if await runtime.hasActiveOperation {
            await runtime.requestOperationCancellation()
            await interrupt(turnID)
            await runtime.waitUntilIdle()
        }
        await deliver(batch)
        await persist()
    }

    /// Called at the ownership release boundary, never from a UI `busy`
    /// observation. The same claim path is used by manual delivery.
    func deliverAutomatically(after turnID: TurnID) async {
        guard let state = await runtime.currentTurnState,
              state.id == turnID,
              state.outcome == .succeeded else {
            // A cancelled or failed turn leaves its queue available for an
            // explicit recovery action, never for an automatic continuation.
            _ = await runtime.pausePendingSteering()
            await persist()
            return
        }
        guard let context = await runtime.steeringContext(for: turnID),
              let batch = await runtime.claimSteeringBatch(
                  for: context,
                  intent: .automatic
              ) else { return }
        await deliver(batch)
        await persist()
    }

    private func deliver(_ batch: SteeringDeliveryBatch) async {
        guard await runtime.ownsSteeringDelivery(batch) else { return }
        guard let deliveryHandler else {
            _ = await runtime.failSteering(
                batch,
                failure: TurnFailure(
                    code: "steering.unconfigured",
                    message: "No steering delivery handler is configured.",
                    isRecoverable: true
                )
            )
            return
        }
        let requests = await runtime.steeringRequests(for: batch)
        guard !requests.isEmpty else {
            _ = await runtime.failSteering(
                batch,
                failure: TurnFailure(
                    code: "steering.missing_request",
                    message: "The claimed steering request could not be found."
                )
            )
            return
        }
        switch await deliveryHandler(batch, requests) {
        case .accepted(let providerTurnID):
            _ = await runtime.acknowledgeSteering(
                batch,
                receipt: SteeringDeliveryReceipt(
                    deliveryID: batch.id,
                    providerTurnID: providerTurnID
                )
            )
        case .failed(let failure):
            _ = await runtime.failSteering(batch, failure: failure)
        case .uncertain:
            _ = await runtime.markSteeringUncertain(batch)
        }
        await persist()
    }

    private static func prompt(for requests: [SteeringRequest]) -> String {
        requests.sorted { $0.sequence < $1.sequence }.map { request in
            "Steering instruction \(request.sequence):\n\(request.text)"
        }.joined(separator: "\n\n")
    }

    private static func displayText(for requests: [SteeringRequest]) -> String {
        requests.sorted { $0.sequence < $1.sequence }
            .map(\.text)
            .joined(separator: "\n\n")
    }
}
