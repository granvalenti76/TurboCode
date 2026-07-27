/// Pure transformations for timeline review receipts.
///
/// Keeping merge policy stateless prevents ChatTimelineStore from accumulating
/// file-edit business rules and makes multi-call edit grouping independently
/// testable.
enum ReviewReceiptReducer {
    static func merging(
        _ payload: DiffPatchBlock,
        patch: String,
        files: [DiffPatchFileChange],
        reviewFiles: [DiffReviewFileSnapshot],
        status: DiffPatchStatus
    ) -> DiffPatchBlock {
        var result = payload
        var patches = result.patches ?? [result.patch]
        patches.append(patch)
        result.patches = patches
        result.patch = patches.joined(separator: "\n")
        result.files = mergedFileChanges(result.files + files)
        result.reviewFiles = mergedReviewFiles(
            existing: result.reviewFiles ?? [],
            incoming: reviewFiles
        )
        result.status = status
        result.errorMessage = nil
        return result
    }

    static func updating(
        _ payload: DiffPatchBlock,
        status: DiffPatchStatus,
        errorMessage: String?
    ) -> DiffPatchBlock {
        var result = payload
        result.status = status
        result.errorMessage = errorMessage
        return result
    }

    private static func mergedFileChanges(
        _ changes: [DiffPatchFileChange]
    ) -> [DiffPatchFileChange] {
        var order: [String] = []
        var totals: [String: (additions: Int, deletions: Int)] = [:]
        for change in changes {
            if totals[change.path] == nil { order.append(change.path) }
            totals[change.path, default: (0, 0)].additions += change.additions
            totals[change.path, default: (0, 0)].deletions += change.deletions
        }
        return order.compactMap { path in
            guard let total = totals[path] else { return nil }
            return DiffPatchFileChange(
                path: path,
                additions: total.additions,
                deletions: total.deletions
            )
        }
    }

    /// Consecutive edits retain the first before-state and final after-state.
    private static func mergedReviewFiles(
        existing: [DiffReviewFileSnapshot],
        incoming: [DiffReviewFileSnapshot]
    ) -> [DiffReviewFileSnapshot] {
        var merged = existing
        for snapshot in incoming {
            if let index = merged.firstIndex(where: { $0.path == snapshot.path }) {
                merged[index] = DiffReviewFileSnapshot(
                    path: snapshot.path,
                    originalText: merged[index].originalText,
                    modifiedText: snapshot.modifiedText
                )
            } else {
                merged.append(snapshot)
            }
        }
        return merged
    }
}
