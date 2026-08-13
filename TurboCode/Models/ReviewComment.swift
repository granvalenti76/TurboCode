import CryptoKit
import Foundation

/// Identifies which document represented by a unified diff owns a reviewed
/// line. Removed lines exist only in the original document; every other line
/// is anchored to the current working-tree document.
nonisolated enum ReviewDiffSide: String, Sendable, Hashable {
    case current
    case original
}

/// A content-backed source location that can be resolved again after Git
/// refreshes the diff and gives every presentation row a new transient ID.
nonisolated struct ReviewLineAnchor: Sendable, Hashable {
    let filePath: String
    let side: ReviewDiffSide
    let lineNumber: Int
    let content: String
    let previousContent: String?
    let nextContent: String?
    let fingerprint: String

    static func make(
        filePath: String,
        lineIndex: Int,
        lines: [DiffLine]
    ) -> ReviewLineAnchor? {
        guard lines.indices.contains(lineIndex) else { return nil }
        let line = lines[lineIndex]
        let side: ReviewDiffSide = line.type == .removed ? .original : .current
        let lineNumber = side == .current ? line.newLineNumber : line.oldLineNumber
        guard let lineNumber else { return nil }

        let previous = neighboringContent(
            before: lineIndex,
            side: side,
            lines: lines
        )
        let next = neighboringContent(
            after: lineIndex,
            side: side,
            lines: lines
        )
        return ReviewLineAnchor(
            filePath: filePath,
            side: side,
            lineNumber: lineNumber,
            content: line.content,
            previousContent: previous,
            nextContent: next,
            fingerprint: fingerprint(
                side: side,
                content: line.content,
                previous: previous,
                next: next
            )
        )
    }

    private static func neighboringContent(
        before index: Int,
        side: ReviewDiffSide,
        lines: [DiffLine]
    ) -> String? {
        guard index > lines.startIndex else { return nil }
        for candidateIndex in stride(from: index - 1, through: lines.startIndex, by: -1) {
            if belongs(lines[candidateIndex], to: side) {
                return lines[candidateIndex].content
            }
        }
        return nil
    }

    private static func neighboringContent(
        after index: Int,
        side: ReviewDiffSide,
        lines: [DiffLine]
    ) -> String? {
        guard index < lines.index(before: lines.endIndex) else { return nil }
        return lines[lines.index(after: index)...]
            .first(where: { belongs($0, to: side) })?
            .content
    }

    private static func belongs(_ line: DiffLine, to side: ReviewDiffSide) -> Bool {
        switch side {
        case .current:
            line.type != .removed && line.newLineNumber != nil
        case .original:
            line.type != .added && line.oldLineNumber != nil
        }
    }

    private static func fingerprint(
        side: ReviewDiffSide,
        content: String,
        previous: String?,
        next: String?
    ) -> String {
        let source = [side.rawValue, previous ?? "", content, next ?? ""]
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// One user-authored request attached to a reviewed source line. Outdated
/// comments remain visible and editable, but cannot be sent until the user
/// removes them or a later refresh resolves their anchor unambiguously.
nonisolated struct ReviewComment: Identifiable, Sendable, Hashable {
    let id: UUID
    var anchor: ReviewLineAnchor
    var body: String
    let createdAt: Date
    var isOutdated: Bool

    init(
        id: UUID = UUID(),
        anchor: ReviewLineAnchor,
        body: String,
        createdAt: Date = .now,
        isOutdated: Bool = false
    ) {
        self.id = id
        self.anchor = anchor
        self.body = body
        self.createdAt = createdAt
        self.isOutdated = isOutdated
    }
}

/// Resolves stored review anchors against a newly captured diff. Content and
/// neighboring lines outrank proximity; ambiguous duplicate matches are never
/// guessed because a wrong review target is worse than an explicit stale state.
nonisolated enum ReviewAnchorResolver {
    static func resolve(
        _ anchor: ReviewLineAnchor,
        in sections: [FileDiffSection]
    ) -> ReviewLineAnchor? {
        guard let section = sections.first(where: { $0.path == anchor.filePath }) else {
            return nil
        }
        let candidates = section.diffLines.indices.compactMap {
            ReviewLineAnchor.make(
                filePath: section.path,
                lineIndex: $0,
                lines: section.diffLines
            )
        }.filter { $0.side == anchor.side }

        let exactLocation = candidates.filter {
            $0.lineNumber == anchor.lineNumber && $0.content == anchor.content
        }
        if exactLocation.count == 1 { return exactLocation[0] }

        let exactContext = candidates.filter { $0.fingerprint == anchor.fingerprint }
        if exactContext.count == 1 { return exactContext[0] }

        let sameContent = candidates.filter { $0.content == anchor.content }
        guard !sameContent.isEmpty else { return nil }
        let ranked = sameContent.map { candidate in
            let contextScore = (candidate.previousContent == anchor.previousContent ? 2 : 0)
                + (candidate.nextContent == anchor.nextContent ? 2 : 0)
            let distance = abs(candidate.lineNumber - anchor.lineNumber)
            return (candidate: candidate, score: contextScore * 1_000 - distance)
        }.sorted { $0.score > $1.score }

        guard let best = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].score == best.score {
            return nil
        }
        // A unique line body is enough to survive an ordinary insertion. When
        // duplicates exist, require at least one matching neighbor as evidence.
        guard sameContent.count == 1
                || best.candidate.previousContent == anchor.previousContent
                || best.candidate.nextContent == anchor.nextContent else {
            return nil
        }
        return best.candidate
    }
}

/// Provider-neutral representation of an explicit "Send review" action.
/// Keeping prompt construction deterministic gives small and large profiles
/// the same precise file/line context without introducing another model tool.
nonisolated struct ReviewRequest: Sendable, Equatable {
    let displayText: String
    let promptText: String
}

nonisolated enum ReviewRequestBuilder {
    static func make(comments: [ReviewComment]) -> ReviewRequest? {
        let valid = comments.filter { !$0.isOutdated }
        guard !valid.isEmpty, valid.count == comments.count else { return nil }
        let sorted = valid.sorted {
            if $0.anchor.filePath != $1.anchor.filePath {
                return $0.anchor.filePath < $1.anchor.filePath
            }
            if $0.anchor.lineNumber != $1.anchor.lineNumber {
                return $0.anchor.lineNumber < $1.anchor.lineNumber
            }
            return $0.createdAt < $1.createdAt
        }

        let noun = sorted.count == 1 ? "comment" : "comments"
        let displayItems = sorted.map { comment in
            "- `\(comment.anchor.filePath):\(comment.anchor.lineNumber)` — \(comment.body)"
        }.joined(separator: "\n")
        let display = "Apply \(sorted.count) review \(noun):\n\n\(displayItems)"

        let promptItems = sorted.enumerated().map { index, comment in
            let side = comment.anchor.side == .current ? "current" : "removed/original"
            let code = comment.anchor.content.isEmpty ? "<blank line>" : comment.anchor.content
            let context = [
                comment.anchor.previousContent.map { "Context before: \($0)" },
                Optional("Reviewed code: \(code)"),
                comment.anchor.nextContent.map { "Context after: \($0)" }
            ].compactMap(\.self).joined(separator: "\n")
            return """
            [\(index + 1)] \(comment.anchor.filePath) — \(side) line \(comment.anchor.lineNumber)
            \(context)
            Comment: \(comment.body)
            """
        }.joined(separator: "\n\n")
        let prompt = """
        Apply the following code-review comments with focused, reviewable edits. Inspect the current surrounding code before changing each file; the line numbers and excerpts identify the reviewed diff snapshot and may have shifted slightly. For removed/original anchors, inspect the Git diff when the reviewed line is absent from the current file.

        \(promptItems)
        """
        return ReviewRequest(displayText: display, promptText: prompt)
    }
}
