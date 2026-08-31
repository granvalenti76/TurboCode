import Foundation

/// Serializes normalized backend events before they reach application
/// presentation. Runtime admission therefore remains executor-neutral even
/// while the current UI presenter stays MainActor-isolated.
actor BackendEventIngress {
    typealias Delivery = @MainActor @Sendable (AgentRuntimeEvent) -> Void

    private let turnID: TurnID
    private let runtime: AgentRuntime
    private let delivery: Delivery
    private let coalescingNanoseconds: UInt64
    private var pendingAssistantText: String?
    private var pendingReasoningText: String?
    private var flushTask: Task<Void, Never>?
    private var isClosed = false

    init(
        turnID: TurnID,
        runtime: AgentRuntime,
        delivery: @escaping Delivery,
        coalescingNanoseconds: UInt64 = 16_000_000
    ) {
        self.turnID = turnID
        self.runtime = runtime
        self.delivery = delivery
        self.coalescingNanoseconds = max(1, coalescingNanoseconds)
    }

    /// Admits one event on the ingress actor and delivers it only after the
    /// Core runtime accepts its turn. Cumulative text snapshots are reduced to
    /// the newest value in the current window; lifecycle and tool events flush
    /// that value before continuing so semantic order remains observable.
    func receive(_ event: AgentRuntimeEvent) async {
        guard !isClosed, event.turnID == turnID else { return }

        switch event {
        case .assistantTextChanged(_, let text):
            guard await runtime.apply(event) else { return }
            pendingAssistantText = text
            scheduleFlush()
        case .reasoningTextChanged(_, let text):
            guard await runtime.apply(event) else { return }
            pendingReasoningText = text
            scheduleFlush()
        case .completed:
            // Settlement is owned by the coordinator after the backend returns;
            // the completion callback is still gated against stale turns here.
            guard await runtime.owns(turnID) else { return }
            await flush()
            await delivery(event)
        case .toolFinished:
            // Tool completion may be a redundant phase transition, but a
            // current receipt must still reach its presenter exactly once.
            guard await runtime.owns(turnID) else { return }
            _ = await runtime.apply(event)
            await flush()
            await delivery(event)
        default:
            guard await runtime.apply(event) else { return }
            await flush()
            await delivery(event)
        }
    }

    /// Forces the latest admitted text to the host. Production uses this at
    /// semantic boundaries; tests use it to make coalescing deterministic.
    func flush() async {
        await flushPending()
    }

    /// Stops accepting callbacks once the provider session has settled. Any
    /// unflushed text is discarded because a missing terminal event means the
    /// provider turn is no longer safe to project.
    func close() {
        isClosed = true
        flushTask?.cancel()
        flushTask = nil
        pendingAssistantText = nil
        pendingReasoningText = nil
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let delay = coalescingNanoseconds
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flushPending() async {
        flushTask?.cancel()
        flushTask = nil

        if let text = pendingAssistantText {
            pendingAssistantText = nil
            await delivery(
                .assistantTextChanged(turnID: turnID, text: text)
            )
        }
        if let text = pendingReasoningText {
            pendingReasoningText = nil
            await delivery(
                .reasoningTextChanged(turnID: turnID, text: text)
            )
        }
    }
}
