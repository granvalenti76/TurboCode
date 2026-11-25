import Foundation
import FoundationModels

/// Converts TurboCode's visual timeline into portable model context. The
/// renderer deliberately omits private reasoning and raw tool chatter while
/// retaining concise, reviewable outcomes from the native widgets.
nonisolated enum RuntimeContextHandoff {
    static let codexSummaryThreshold = 10_000
    static let summaryTransferPrompt = "Context transferred from the previous model runtime."

    static func shouldSummarizeCodexContext(lastTotalTokens: Int?) -> Bool {
        guard let lastTotalTokens else { return false }
        return lastTotalTokens > codexSummaryThreshold
    }

    static func render(
        blocks: [ChatBlock],
        after boundaryBlockID: String? = nil,
        maximumCharacters: Int? = nil
    ) -> String {
        let selectedBlocks: ArraySlice<ChatBlock>
        if let boundaryBlockID,
           let boundaryIndex = blocks.firstIndex(where: { $0.id == boundaryBlockID }) {
            selectedBlocks = blocks[blocks.index(after: boundaryIndex)...]
        } else {
            selectedBlocks = blocks[...]
        }

        let sections = selectedBlocks.compactMap(renderBlock)
        let context = sections.joined(separator: "\n\n")
        guard let maximumCharacters, context.count > maximumCharacters else {
            return context
        }

        // Preserve the newest state when a failed model summary requires a
        // deterministic fallback. A clear marker prevents the destination
        // model from assuming this is the complete conversation.
        return "[Earlier context omitted during runtime handoff]\n\n"
            + String(context.suffix(maximumCharacters))
    }

    static let compactionOmissionMarker = "[Earlier context omitted during compaction]"

    /// Renders a conversation for local compaction within `maximumCharacters`.
    ///
    /// Unlike `render`, which keeps only the newest characters, this keeps the
    /// first user request whole and fills the rest with the newest sections.
    /// The first request usually states the task; repeated automatic
    /// compactions would otherwise drop it first and leave the model knowing
    /// what it did recently but not why. Cuts fall between sections, never
    /// inside one, except when the newest section alone exceeds the budget.
    static func renderKeepingFirstRequest(
        blocks: [ChatBlock],
        maximumCharacters: Int
    ) -> String {
        let sections = blocks.compactMap { block in
            renderBlock(block).map { (kind: block.kind, text: $0) }
        }
        let separator = "\n\n"
        let full = sections.map(\.text).joined(separator: separator)
        guard full.count > maximumCharacters else { return full }

        // A first request larger than half the budget is itself shortened, so
        // the newest state always keeps at least half of the space.
        let firstIndex = sections.firstIndex { $0.kind == .user }
        var pinned = firstIndex.map { sections[$0].text } ?? ""
        let pinnedLimit = maximumCharacters / 2
        if pinned.count > pinnedLimit {
            pinned = String(pinned.prefix(max(0, pinnedLimit - 1))) + "…"
        }
        let head = pinned.isEmpty
            ? compactionOmissionMarker
            : pinned + separator + compactionOmissionMarker
        var remaining = maximumCharacters - head.count - separator.count

        var tail: [String] = []
        var index = sections.endIndex
        let lowerBound = firstIndex.map { $0 + 1 } ?? sections.startIndex
        while index > lowerBound, remaining > 0 {
            index -= 1
            let text = sections[index].text
            let cost = text.count + (tail.isEmpty ? 0 : separator.count)
            if cost <= remaining {
                tail.insert(text, at: 0)
                remaining -= cost
            } else {
                if tail.isEmpty {
                    // The newest section alone is too large: keep its end,
                    // where the latest state of a long message usually is.
                    tail.insert("…" + String(text.suffix(max(0, remaining - 1))), at: 0)
                }
                break
            }
        }
        return ([head] + tail).joined(separator: separator)
    }

    static func transcript(from blocks: [ChatBlock]) -> [Transcript.Entry] {
        SessionRebuildHistory.fromVisibleBlocks(blocks)
    }

    static func transcript(fromSummary summary: String) -> [Transcript.Entry] {
        let prompt = Transcript.Segment.text(
            Transcript.TextSegment(
                content: summaryTransferPrompt
            )
        )
        let response = Transcript.Segment.text(
            Transcript.TextSegment(content: summary)
        )
        return [
            .prompt(Transcript.Prompt(segments: [prompt])),
            .response(Transcript.Response(assetIDs: [], segments: [response]))
        ]
    }

    private static func renderBlock(_ block: ChatBlock) -> String? {
        switch block.kind {
        case .user:
            return meaningful(block.text).map { "USER:\n\($0)" }
        case .assistant, .productGuide:
            return meaningful(block.text).map { "ASSISTANT:\n\($0)" }
        case .diffPatch:
            guard let patch = block.diffPatch else { return nil }
            let files = patch.files.map {
                "\($0.path) (+\($0.additions)/-\($0.deletions))"
            }.joined(separator: ", ")
            return "FILE EDIT: \(patch.status.rawValue); \(files)"
        case .gitCommit:
            guard let commit = block.gitCommit else { return nil }
            let files = commit.files.map(\.path).joined(separator: ", ")
            return """
            GIT COMMIT: \(commit.status.rawValue); \(commit.shortHash) \
            \(commit.message); branch \(commit.branch); files: \(files)
            """
        case .gitStatus:
            guard let status = block.gitStatus else { return nil }
            let files = status.files.map {
                "\($0.path) (+\($0.additions)/-\($0.deletions))"
            }.joined(separator: ", ")
            return """
            GIT STATUS: branch \(status.branch); \(status.changedFilesCount) changed; \
            files with line statistics: \(files)
            """
        case .workspaceListing:
            guard let listing = block.workspaceListing else { return nil }
            if let errorMessage = listing.errorMessage {
                return "WORKSPACE LISTING: \(listing.path); error: \(errorMessage)"
            }
            let names = listing.entries.prefix(40).map(\.relativePath)
                .joined(separator: ", ")
            let suffix = listing.isTruncated ? "; truncated" : ""
            return """
            WORKSPACE LISTING: \(listing.path); \(listing.totalCount) entries\
            \(suffix): \(names)
            """
        case .pluginWidget:
            guard let widget = block.pluginWidget else { return nil }
            return "PLUGIN WIDGET: \(widget.title) (\(widget.pluginID)/\(widget.widgetID))"
        case .editorialPublication:
            guard let publication = block.editorialPublication else { return nil }
            return "EDITORIAL PUBLICATION: \(publication.relativePath); \(publication.wordCount) words"
        case .reasoning, .tool, .approval, .review, .compaction:
            return nil
        }
    }

    private static func meaningful(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
