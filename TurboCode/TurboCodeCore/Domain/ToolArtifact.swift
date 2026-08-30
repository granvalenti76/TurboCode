import Foundation

/// Stable identity plus immutable review data produced by one edit tool call.
///
/// The transaction identifier remains separate from ``DiffPatchBlock`` because
/// it correlates transient tool execution, while the block is also persisted as
/// durable conversation evidence after a host accepts the owning turn.
nonisolated struct DiffPatchReceipt: Codable, Hashable, Sendable {
    let transactionID: String
    let block: DiffPatchBlock
}

/// Signals that repository-derived host projections became stale even when a
/// Git operation has no dedicated visual receipt, such as stage or switch.
/// Hosts decide whether and how to refresh; the Core contract owns no UI state.
nonisolated struct RepositoryMutationReceipt: Codable, Hashable, Sendable {
    let workspaceRoot: String
}
