import Observation

/// Owns transient tool activity and approval presentation state.
///
/// Execution remains in ChatStore: this store only enforces ordering,
/// deduplication, and stable activity replacement so UI state cannot diverge
/// between native, remote, and Codex tool paths.
@MainActor
@Observable
final class ToolInteractionStore {
    var activities: [ToolActivity] = []
    var pendingApproval: ApprovalRequest?

    var activeActivity: ToolActivity? {
        activities.last
    }

    private var queuedApprovals: [ApprovalRequest] = []

    /// Presents each approval identifier at most once and preserves arrival
    /// order for destructive operations awaiting user review.
    func enqueueApproval(_ request: ApprovalRequest) {
        guard pendingApproval?.id != request.id,
              !queuedApprovals.contains(where: { $0.id == request.id }) else { return }

        if pendingApproval == nil {
            pendingApproval = request
        } else {
            queuedApprovals.append(request)
        }
    }

    /// Returns the visible request while atomically advancing the queue. The
    /// caller can then execute its backend-specific approval side effect.
    func takePendingApproval() -> ApprovalRequest? {
        guard let request = pendingApproval else { return nil }
        advanceApprovalQueue()
        return request
    }

    func dismissApproval(id: String) {
        if pendingApproval?.id == id {
            advanceApprovalQueue()
        } else {
            queuedApprovals.removeAll { $0.id == id }
        }
    }

    /// Replaces an activity with the same call identity before appending it as
    /// the most recent item shown by the timeline.
    func beginActivity(id: String, summary: String) {
        endActivity(id: id)
        activities.append(ToolActivity(id: id, summary: summary))
    }

    func endActivity(id: String) {
        activities.removeAll { $0.id == id }
    }

    func clearActivities() {
        activities.removeAll()
    }

    /// Removes and returns every unresolved approval when an outer response is
    /// stopped. The caller still owns provider-specific rejection so no hidden
    /// continuation survives after the presentation is cleared.
    func takeAllApprovals() -> [ApprovalRequest] {
        let requests = [pendingApproval].compactMap { $0 } + queuedApprovals
        pendingApproval = nil
        queuedApprovals.removeAll()
        return requests
    }

    private func advanceApprovalQueue() {
        pendingApproval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst()
    }
}
