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

    /// Whether a local llama-server conversation should be compacted before
    /// the next message. `usage` is the fill reported by the previous turn;
    /// it exists only for llama-server, whose `/props` gives the loaded
    /// context, and it is cleared by every rebuild, so a compaction cannot
    /// repeat until a new turn reports again. The check runs between turns
    /// only: compacting inside a running tool loop would cut the turn.
    static func shouldAutoCompact(
        backend: ModelBackend,
        usage: LlamaContextUsage?,
        thresholdPercent: Int
    ) -> Bool {
        guard backend == .llamaServer, thresholdPercent > 0, let usage else {
            return false
        }
        return usage.usedTokens * 100 >= thresholdPercent * usage.contextSize
    }

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
    ///
    /// `toolEntries` is the model transcript the tool receipts come from: the
    /// timeline does not hold native tool calls, only their widgets. Receipts
    /// take at most a fifth of the budget so the conversation keeps the rest.
    static func localCompaction(
        from blocks: [ChatBlock],
        toolEntries: [Transcript.Entry] = [],
        maximumCharacters: Int
    ) -> LocalCompaction? {
        let sourceCharacters = blocks
            .filter { $0.kind != .compaction }
            .reduce(0) { $0 + $1.text.count }
        let fullRender = RuntimeContextHandoff.render(blocks: blocks)
        guard !fullRender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let receipts = toolReceiptSection(
            from: toolEntries,
            maximumCharacters: maximumCharacters / 5
        )
        let rendered = RuntimeContextHandoff.renderKeepingFirstRequest(
            blocks: blocks,
            maximumCharacters: maximumCharacters - receipts.count
        )
        let receiptPart = receipts.isEmpty ? "" : receipts + "\n\n"
        let summary = """
        Context compacted by TurboCode for the next local Llama turn.
        Preserve the user's goals, accepted decisions, and completed workspace outcomes.
        Completed tool calls are listed without their raw output; read a file \
        again before relying on its exact contents.

        \(receiptPart)CONVERSATION:
        \(rendered)
        """
        return LocalCompaction(
            summary: summary,
            history: RuntimeContextHandoff.transcript(fromSummary: summary),
            sourceCharacters: max(sourceCharacters, fullRender.count),
            retainedCharacters: rendered.count + receipts.count
        )
    }

    /// One line per completed tool call, newest kept when the budget is short.
    ///
    /// Without these lines a compacted model no longer knows which files it
    /// read or which commands failed, and repeats that work. Only short
    /// argument values are kept: long ones are file contents or patches.
    static func toolReceiptSection(
        from entries: [Transcript.Entry],
        maximumCharacters: Int
    ) -> String {
        var outputs: [String: String] = [:]
        for entry in entries {
            if case .toolOutput(let output) = entry {
                outputs[output.id] = segmentText(output.segments)
            }
        }
        var receipts: [String] = []
        for entry in entries {
            guard case .toolCalls(let calls) = entry else { continue }
            for call in calls {
                // A call without an output never completed; it is not a receipt.
                guard let output = outputs[call.id] else { continue }
                receipts.append(toolReceipt(for: call, output: output))
            }
        }
        guard !receipts.isEmpty else { return "" }

        let header = "TOOLS USED (oldest first):"
        var kept: [String] = []
        var used = header.count
        for receipt in receipts.reversed() {
            let cost = receipt.count + 1
            guard used + cost <= maximumCharacters else { break }
            kept.insert(receipt, at: 0)
            used += cost
        }
        guard !kept.isEmpty else { return "" }
        var lines = [header]
        if kept.count < receipts.count {
            lines.append("- (\(receipts.count - kept.count) earlier calls omitted)")
        }
        return (lines + kept).joined(separator: "\n")
    }

    private static let receiptArgumentLimit = 120
    private static let receiptOutcomeLimit = 80

    private static func toolReceipt(
        for call: Transcript.ToolCall,
        output: String
    ) -> String {
        var line = "- \(call.toolName)"
        let arguments = receiptArguments(call.arguments.jsonString)
        if !arguments.isEmpty {
            line += " " + arguments
        }
        let outcome = output
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if !outcome.isEmpty {
            line += " → " + clipped(outcome, to: receiptOutcomeLimit)
        }
        return line
    }

    /// Short scalar arguments in key order, so the same call always renders
    /// the same line.
    private static func receiptArguments(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ""
        }
        var parts: [String] = []
        for key in object.keys.sorted() {
            let value: String
            switch object[key] {
            case let text as String:
                let single = text.replacingOccurrences(of: "\n", with: " ")
                guard !single.isEmpty, single.count <= receiptArgumentLimit else { continue }
                value = single
            case let number as NSNumber:
                value = number.stringValue
            default:
                continue
            }
            parts.append("\(key): \(value)")
        }
        return clipped(parts.joined(separator: ", "), to: receiptArgumentLimit + 40)
    }

    private static func segmentText(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            default: nil
            }
        }.joined(separator: "\n")
    }

    private static func clipped(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
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
