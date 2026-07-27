import Foundation
import FoundationModels

/// Prepares conversation history for a newly constructed model session. The
/// destination profile always supplies fresh instructions and tool definitions.
nonisolated enum SessionRebuildHistory {
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
                    .diffPatch, .gitCommit, .workspaceListing:
                return nil
            }
        }
    }
}
