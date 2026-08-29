import Foundation
import FoundationModels

/// Prepares conversation history for a newly constructed model session. The
/// destination profile always supplies fresh instructions and tool definitions.
nonisolated enum SessionRebuildHistory {
    /// The local handoff carries enough accounting data for the UI and
    /// diagnostics without changing the Apple on-device compaction contract.
    nonisolated struct LocalCompaction: Sendable {
        let summary: String
        let history: [Transcript.Entry]
        let sourceCharacters: Int
        let retainedCharacters: Int
    }

    /// Apple on-device remains reliable for roughly eight conversational turns.
    /// Before the ninth question, rebuild the context from durable outcomes
    /// instead of carrying every completed call and raw output forward.
    static let onDeviceCompactionThreshold = 8

    static func userTurnCount(in transcript: Transcript) -> Int {
        transcript.reduce(into: 0) { count, entry in
            guard case .prompt(let prompt) = entry else { return }
            let isCompactionHandoff = prompt.segments.contains { segment in
                guard case .text(let text) = segment else { return false }
                return text.content == RuntimeContextHandoff.summaryTransferPrompt
            }
            if !isCompactionHandoff {
                count += 1
            }
        }
    }

    /// Scales the local handoff budget with the declared Llama context window.
    /// The cap leaves room for runtime instructions, tools, and the next reply.
    static func localCompactionCharacterLimit(contextWindowTokens: Int?) -> Int {
        let tokens = max(1, contextWindowTokens ?? 32_768)
        return max(8_000, min(120_000, tokens * 3 / 8))
    }

    /// Builds a Llama-specific handoff. This is deliberately separate from
    /// `onDeviceCompaction` so Apple on-device behavior remains untouched.
    static func localCompaction(
        from blocks: [ChatBlock],
        maximumCharacters: Int
    ) -> LocalCompaction? {
        let sourceCharacters = blocks
            .filter { $0.kind != .compaction }
            .reduce(0) { $0 + $1.text.count }
        let fullRender = RuntimeContextHandoff.render(blocks: blocks)
        guard !fullRender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let rendered = RuntimeContextHandoff.render(
            blocks: blocks,
            maximumCharacters: maximumCharacters
        )
        let summary = """
        Context compacted by TurboCode for the next local Llama turn.
        Preserve the user's goals, accepted decisions, and completed workspace outcomes.
        Completed tool calls and their raw output were omitted.

        \(rendered)
        """
        return LocalCompaction(
            summary: summary,
            history: RuntimeContextHandoff.transcript(fromSummary: summary),
            sourceCharacters: max(sourceCharacters, fullRender.count),
            retainedCharacters: rendered.count
        )
    }

    /// Produces a compact, model-readable handoff that keeps user requests,
    /// assistant decisions, and native receipts while dropping tool chatter.
    static func onDeviceCompaction(
        from blocks: [ChatBlock]
    ) -> (summary: String, history: [Transcript.Entry])? {
        let rendered = RuntimeContextHandoff.render(
            blocks: blocks,
            maximumCharacters: 7_000
        )
        guard !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let summary = """
        Context compacted by TurboCode before the next on-device turn.
        Preserve the user's goals, accepted decisions, and completed workspace outcomes.
        Completed tool calls and their raw output were omitted.

        \(rendered)
        """
        return (
            summary,
            RuntimeContextHandoff.transcript(fromSummary: summary)
        )
    }

    static func prepare(
        _ transcript: Transcript,
        keepingHistory: Bool,
        discardingCapabilityContext: Bool
    ) -> [Transcript.Entry] {
        guard keepingHistory else { return [] }
        return transcript.filter { entry in
            switch entry {
            case .instructions:
                return false
            case .toolCalls, .toolOutput, .reasoning:
                return !discardingCapabilityContext
            case .prompt, .response:
                return true
            @unknown default:
                return true
            }
        }
    }

    /// Best-effort migration for sessions saved before semantic transcripts
    /// were persisted. Presentation-only blocks are intentionally ignored.
    static func fromVisibleBlocks(_ blocks: [ChatBlock]) -> [Transcript.Entry] {
        blocks.compactMap { block in
            let segment = Transcript.Segment.text(
                Transcript.TextSegment(content: block.text)
            )
            switch block.kind {
            case .user:
                return .prompt(Transcript.Prompt(segments: [segment]))
            case .assistant, .productGuide:
                guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return .response(Transcript.Response(assetIDs: [], segments: [segment]))
            case .reasoning, .tool, .approval, .review, .compaction,
                    .diffPatch, .gitCommit, .gitStatus, .workspaceListing,
                    .pluginWidget, .editorialPublication:
                return nil
            }
        }
    }
}
