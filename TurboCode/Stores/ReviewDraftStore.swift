import Foundation
import Observation

/// Owns the ephemeral reviews assembled in the Changes inspector and Markdown
/// file previews. Comments survive panel dismissal and content refreshes, but
/// are intentionally cleared when the user changes workspace or conversation.
@MainActor
@Observable
final class ReviewDraftStore {
    private(set) var comments: [ReviewComment] = []
    private(set) var workspaceRoot = ""

    var outdatedCount: Int { comments.count(where: \.isOutdated) }
    var canSend: Bool { !comments.isEmpty && outdatedCount == 0 }

    func begin(workspaceRoot: String) {
        guard self.workspaceRoot != workspaceRoot else { return }
        self.workspaceRoot = workspaceRoot
        comments = []
    }

    /// Creates or updates the single comment attached to an anchored line.
    /// Reusing an existing ID preserves creation ordering and indicator state.
    @discardableResult
    func upsert(
        id: UUID?,
        anchor: ReviewLineAnchor,
        body: String
    ) -> ReviewComment? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let id, let index = comments.firstIndex(where: { $0.id == id }) {
            comments[index].anchor = anchor
            comments[index].body = trimmed
            comments[index].isOutdated = false
            return comments[index]
        }
        if let index = comments.firstIndex(where: {
            !$0.isOutdated
                && $0.anchor.filePath == anchor.filePath
                && $0.anchor.origin == anchor.origin
                && $0.anchor.side == anchor.side
                && $0.anchor.lineNumber == anchor.lineNumber
                && $0.anchor.content == anchor.content
        }) {
            comments[index].body = trimmed
            comments[index].anchor = anchor
            return comments[index]
        }

        let comment = ReviewComment(anchor: anchor, body: trimmed)
        comments.append(comment)
        return comment
    }

    func remove(_ id: UUID) {
        comments.removeAll { $0.id == id }
    }

    func discardAll() {
        comments = []
    }

    /// Removes only the comments admitted by one review surface after that
    /// surface has durably handed its request to the conversation timeline.
    func discard(ids: Set<UUID>) {
        comments.removeAll { ids.contains($0.id) }
    }

    /// Reconciles comments only after a complete Git snapshot has been
    /// published. A loading placeholder must never make every anchor stale.
    func reconcile(workspaceRoot: String, sections: [FileDiffSection]) {
        begin(workspaceRoot: workspaceRoot)
        comments = comments.map { comment in
            guard comment.anchor.origin == .gitDiff else { return comment }
            var updated = comment
            if let anchor = ReviewAnchorResolver.resolve(comment.anchor, in: sections) {
                updated.anchor = anchor
                updated.isOutdated = false
            } else {
                updated.isOutdated = true
            }
            return updated
        }
    }

    /// Reanchors annotations against the current bounded Markdown snapshot.
    /// Git refreshes deliberately ignore these comments, while each file
    /// preview refresh updates only the annotations that belong to that path.
    func reconcileWorkspaceFile(
        relativePath: String,
        lines: [DiffLine]
    ) {
        let section = FileDiffSection(
            path: relativePath,
            added: 0,
            removed: 0,
            diffLines: lines
        )
        comments = comments.map { comment in
            guard comment.anchor.origin == .workspaceFile,
                  comment.anchor.filePath == relativePath else { return comment }
            var updated = comment
            if let anchor = ReviewAnchorResolver.resolve(comment.anchor, in: [section]) {
                updated.anchor = anchor
                updated.isOutdated = false
            } else {
                updated.isOutdated = true
            }
            return updated
        }
    }
}
