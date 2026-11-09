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
        .map(replacingImageAttachments)
    }

    /// Rebuilds may target a different model, and a server without vision rejects
    /// any request whose history holds an image, which would break every later
    /// turn in the conversation. The image is dropped for all rebuilds because the
    /// target's support is only known asynchronously. Keeping the entry `id` lets
    /// interrupted-turn repair still match this history against its baseline.
    ///
    /// Images arrive in two kinds of entry: a prompt the user attached them to,
    /// and the output of a tool that showed one to the model. Both are covered,
    /// because either is enough for the server to refuse the request.
    private static func replacingImageAttachments(
        in entry: Transcript.Entry
    ) -> Transcript.Entry {
        switch entry {
        case .prompt(var prompt):
            guard let segments = replacingImageAttachments(in: prompt.segments) else { return entry }
            prompt.segments = segments
            return .prompt(prompt)
        case .toolOutput(var output):
            guard let segments = replacingImageAttachments(in: output.segments) else { return entry }
            output.segments = segments
            return .toolOutput(output)
        default:
            return entry
        }
    }

    /// Returns `nil` when nothing was replaced, so untouched entries are passed
    /// through as the same value.
    private static func replacingImageAttachments(
        in segments: [Transcript.Segment]
    ) -> [Transcript.Segment]? {
        var didReplace = false
        let replaced = segments.map { segment in
            guard case .attachment = segment else { return segment }
            didReplace = true
            return textSegment("[Image no longer available]")
        }
        return didReplace ? replaced : nil
    }

    /// Repairs the semantic history of a provider turn that was cancelled
    /// before Foundation Models committed a complete transcript entry set.
    /// Existing turn-local entries win so completed tool calls are retained;
    /// only missing prompt, reasoning, and partial response entries are added.
    ///
    /// The provider delta is trusted only when `current` still starts with the
    /// exact baseline entries (by identity); a rewritten history yields no
    /// delta rather than misaligned entries. Tool exchanges cut off by the
    /// interruption are dropped: a call without its output is rejected by
    /// OpenAI-compatible servers on the next request.
    static func reconcilingInterruptedTurn(
        baseline: [Transcript.Entry],
        current: [Transcript.Entry],
        prompt: String,
        reasoning: String,
        response: String
    ) -> [Transcript.Entry] {
        let extendsBaseline = current.count >= baseline.count
            && current.prefix(baseline.count).map(\.id) == baseline.map(\.id)
        let currentDelta = extendsBaseline
            ? Array(current.dropFirst(baseline.count))
            : []
        var turnEntries = droppingIncompleteToolExchanges(currentDelta)

        let containsPrompt = turnEntries.contains { entry in
            if case .prompt = entry { return true }
            return false
        }
        if !containsPrompt {
            turnEntries.insert(.prompt(promptEntry(prompt)), at: 0)
        }

        let meaningfulReasoning = reasoning.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let containsReasoning = turnEntries.contains { entry in
            if case .reasoning = entry { return true }
            return false
        }
        if !meaningfulReasoning.isEmpty, !containsReasoning {
            let insertionIndex = turnEntries.firstIndex { entry in
                switch entry {
                case .toolCalls, .response:
                    return true
                default:
                    return false
                }
            } ?? turnEntries.endIndex
            turnEntries.insert(
                .reasoning(reasoningEntry(reasoning)),
                at: insertionIndex
            )
        }

        let meaningfulResponse = response.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let containsResponse = turnEntries.contains { entry in
            if case .response = entry { return true }
            return false
        }
        if !meaningfulResponse.isEmpty, !containsResponse {
            turnEntries.append(.response(responseEntry(response)))
        }

        return baseline + turnEntries
    }

    /// Keeps only tool-call entries whose every call has an output, and only
    /// outputs whose call survived, so the history stays provider-valid.
    static func droppingIncompleteToolExchanges(
        _ entries: [Transcript.Entry]
    ) -> [Transcript.Entry] {
        let outputIDs = Set(entries.compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry else { return nil }
            return output.id
        })
        var keptCallIDs: Set<String> = []
        let withoutIncompleteCalls = entries.filter { entry in
            guard case .toolCalls(let calls) = entry else { return true }
            let ids = calls.map(\.id)
            guard !ids.isEmpty, ids.allSatisfy(outputIDs.contains) else {
                return false
            }
            keptCallIDs.formUnion(ids)
            return true
        }
        return withoutIncompleteCalls.filter { entry in
            guard case .toolOutput(let output) = entry else { return true }
            return keptCallIDs.contains(output.id)
        }
    }

    private static func promptEntry(_ text: String) -> Transcript.Prompt {
        Transcript.Prompt(segments: [textSegment(text)])
    }

    private static func reasoningEntry(_ text: String) -> Transcript.Reasoning {
        Transcript.Reasoning(segments: [textSegment(text)])
    }

    private static func responseEntry(_ text: String) -> Transcript.Response {
        Transcript.Response(assetIDs: [], segments: [textSegment(text)])
    }

    private static func textSegment(_ text: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(content: text))
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
