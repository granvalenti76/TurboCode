import Foundation
import FoundationModels

/// A reversible overlay applied to the canonical provider transcript.
///
/// The stored transcript is never rewritten when context is excluded. Stable
/// tool-call identifiers describe the projection so later branch support can
/// inherit the same context view without copying or mutating raw history.
nonisolated public struct TranscriptContextProjection: Codable, Equatable, Sendable {
    public private(set) var excludedToolCallIDs: [String]

    nonisolated public static let empty = TranscriptContextProjection()

    nonisolated public init(excludedToolCallIDs: [String] = []) {
        self.excludedToolCallIDs = Array(Set(excludedToolCallIDs)).sorted()
    }

    nonisolated public var isEmpty: Bool {
        excludedToolCallIDs.isEmpty
    }

    nonisolated func applying(to entries: [Transcript.Entry]) -> [Transcript.Entry] {
        let excluded = Set(excludedToolCallIDs)
        guard !excluded.isEmpty else { return entries }

        let outputIDs: Set<String> = Set(entries.compactMap { entry -> String? in
            guard case .toolOutput(let output) = entry else { return nil }
            return output.id
        })
        let safelyExcludedIDs = Set(entries.flatMap { entry -> [String] in
            guard case .toolCalls(let calls) = entry else { return [] }
            let callIDs = calls.map(\.id)
            guard !callIDs.isEmpty,
                  callIDs.allSatisfy(excluded.contains),
                  callIDs.allSatisfy(outputIDs.contains) else { return [] }
            return callIDs
        })

        return entries.filter { entry in
            switch entry {
            case .toolCalls(let calls):
                let callIDs = calls.map(\.id)
                return callIDs.isEmpty || !callIDs.allSatisfy(safelyExcludedIDs.contains)
            case .toolOutput(let output):
                return !safelyExcludedIDs.contains(output.id)
            default:
                return true
            }
        }
    }
}

/// Provider-neutral data consumed by the transcript sheet. Views receive only
/// immutable display values and stable selection identifiers, never a live
/// `LanguageModelSession` or mutable Foundation Models transcript.
nonisolated struct TranscriptContextPresentation: Equatable, Sendable {
    let conversationItems: [TranscriptContextItem]
    let entryItems: [TranscriptContextItem]
    let groups: [TranscriptToolExchangeGroup]
    let turnBoundaries: [TranscriptTurnBoundary]
    let excludedGroupIDs: Set<String>
    let totalEstimatedTokens: Int

    nonisolated static let unavailable = TranscriptContextPresentation(
        conversationItems: [],
        entryItems: [],
        groups: [],
        turnBoundaries: [],
        excludedGroupIDs: [],
        totalEstimatedTokens: 0
    )

    nonisolated var hasTranscript: Bool {
        !entryItems.isEmpty
    }
}

/// A safe future fork point after a completed assistant response. The ordinal
/// remains stable while canonical history is append-only; compaction creates a
/// deliberate new history root rather than pretending old branches still fit.
nonisolated struct TranscriptTurnBoundary: Identifiable, Equatable, Sendable {
    let id: String
    let turnOrdinal: Int
    let afterEntryIndex: Int
}

nonisolated struct TranscriptContextItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case instructions
        case user
        case assistant
        case reasoning
        case toolExchange
        case toolCall
        case toolOutput
        case unknown
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let estimatedTokens: Int
    let groupID: String?
}

/// One selectable unit consisting of a tool-call entry and every matching
/// output. Incomplete exchanges are deliberately not selectable: removing
/// only one side would produce an invalid provider transcript.
nonisolated struct TranscriptToolExchangeGroup: Identifiable, Equatable, Sendable {
    let id: String
    let toolCallIDs: [String]
    let toolNames: [String]
    let entryIndices: [Int]
    let estimatedTokens: Int

    nonisolated var title: String {
        toolNames.count == 1
            ? toolNames[0]
            : "\(toolNames.count) completed tool calls"
    }
}

/// Pure projection and presentation logic kept outside the observable stores
/// so transcript safety rules remain focused and independently testable.
nonisolated enum TranscriptContextProjector {
    /// Read-only fallback for runtimes that keep their semantic transcript
    /// outside TurboCode. It preserves the general-purpose inspection surface
    /// without pretending timeline blocks can be edited as provider history.
    nonisolated static func presentation(
        blocks: [ChatBlock]
    ) -> TranscriptContextPresentation {
        let items = blocks.map { block in
            let values = displayValues(for: block.kind)
            return TranscriptContextItem(
                id: "block:\(block.id)",
                kind: values.kind,
                title: values.title,
                detail: block.text,
                estimatedTokens: estimatedTokens(for: block.text),
                groupID: nil
            )
        }
        var turnOrdinal = 0
        let boundaries: [TranscriptTurnBoundary] = blocks.enumerated().compactMap {
            index, block -> TranscriptTurnBoundary? in
            guard block.kind == .assistant else { return nil }
            turnOrdinal += 1
            return TranscriptTurnBoundary(
                id: "turn:\(turnOrdinal)",
                turnOrdinal: turnOrdinal,
                afterEntryIndex: index
            )
        }
        return TranscriptContextPresentation(
            conversationItems: items,
            entryItems: items,
            groups: [],
            turnBoundaries: boundaries,
            excludedGroupIDs: [],
            totalEstimatedTokens: items.reduce(0) { $0 + $1.estimatedTokens }
        )
    }

    nonisolated static func presentation(
        transcript: Transcript,
        projection: TranscriptContextProjection
    ) -> TranscriptContextPresentation {
        let entries = Array(transcript)
        let groups = completedToolExchangeGroups(in: entries)
        let groupByEntryIndex = Dictionary(
            groups.flatMap { group in
                group.entryIndices.map { ($0, group) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let excludedCallIDs = Set(projection.excludedToolCallIDs)
        let excludedGroupIDs = Set(groups.compactMap { group in
            group.toolCallIDs.allSatisfy(excludedCallIDs.contains) ? group.id : nil
        })

        let entryItems = entries.enumerated().map { index, entry in
            entryItem(
                entry,
                index: index,
                group: groupByEntryIndex[index]
            )
        }

        var conversationItems: [TranscriptContextItem] = []
        for (index, entry) in entries.enumerated() {
            if let group = groupByEntryIndex[index] {
                guard group.entryIndices.first == index else { continue }
                conversationItems.append(groupItem(group))
                continue
            }
            if case .instructions = entry { continue }
            conversationItems.append(entryItem(entry, index: index, group: nil))
        }

        return TranscriptContextPresentation(
            conversationItems: conversationItems,
            entryItems: entryItems,
            groups: groups,
            turnBoundaries: turnBoundaries(in: entries),
            excludedGroupIDs: excludedGroupIDs,
            totalEstimatedTokens: entryItems.reduce(0) { $0 + $1.estimatedTokens }
        )
    }

    nonisolated static func turnBoundaries(
        in entries: [Transcript.Entry]
    ) -> [TranscriptTurnBoundary] {
        var ordinal = 0
        return entries.enumerated().compactMap { index, entry in
            guard case .response = entry else { return nil }
            ordinal += 1
            return TranscriptTurnBoundary(
                id: "turn:\(ordinal)",
                turnOrdinal: ordinal,
                afterEntryIndex: index
            )
        }
    }

    nonisolated static func projection(
        selecting groupIDs: Set<String>,
        in transcript: Transcript
    ) -> TranscriptContextProjection {
        let callIDs = completedToolExchangeGroups(in: Array(transcript))
            .filter { groupIDs.contains($0.id) }
            .flatMap(\.toolCallIDs)
        return TranscriptContextProjection(excludedToolCallIDs: callIDs)
    }

    nonisolated static func completedToolExchangeGroups(
        in entries: [Transcript.Entry]
    ) -> [TranscriptToolExchangeGroup] {
        let outputIndicesByID = entries.enumerated().reduce(
            into: [String: [Int]]()
        ) { result, pair in
            guard case .toolOutput(let output) = pair.element else { return }
            result[output.id, default: []].append(pair.offset)
        }

        return entries.enumerated().compactMap { index, entry in
            guard case .toolCalls(let calls) = entry else { return nil }
            let values = Array(calls)
            let callIDs = values.map(\.id)
            guard !callIDs.isEmpty,
                  callIDs.allSatisfy({ outputIndicesByID[$0]?.isEmpty == false }) else {
                return nil
            }

            let outputIndices = callIDs.flatMap { outputIndicesByID[$0] ?? [] }
            let indices = Array(Set([index] + outputIndices)).sorted()
            let rendered = indices.map { render(entries[$0]) }.joined(separator: "\n")
            return TranscriptToolExchangeGroup(
                id: "tool-exchange:" + callIDs.sorted().joined(separator: "|"),
                toolCallIDs: callIDs,
                toolNames: values.map(\.toolName),
                entryIndices: indices,
                estimatedTokens: estimatedTokens(for: rendered)
            )
        }
    }

    private nonisolated static func entryItem(
        _ entry: Transcript.Entry,
        index: Int,
        group: TranscriptToolExchangeGroup?
    ) -> TranscriptContextItem {
        let rendered = render(entry)
        let values: (TranscriptContextItem.Kind, String, String)
        switch entry {
        case .instructions(let instructions):
            values = (.instructions, "Instructions", text(instructions.segments))
        case .prompt(let prompt):
            values = (.user, "User", text(prompt.segments))
        case .response(let response):
            values = (.assistant, "Assistant", text(response.segments))
        case .reasoning(let reasoning):
            values = (.reasoning, "Reasoning", text(reasoning.segments))
        case .toolCalls(let calls):
            let names = calls.map(\.toolName)
            values = (
                .toolCall,
                names.count == 1 ? names[0] : "\(names.count) tool calls",
                calls.map { "\($0.toolName)(\($0.arguments))" }.joined(separator: "\n")
            )
        case .toolOutput(let output):
            values = (.toolOutput, "\(output.toolName) result", text(output.segments))
        @unknown default:
            values = (.unknown, "Transcript entry", rendered)
        }

        return TranscriptContextItem(
            id: "entry:\(index)",
            kind: values.0,
            title: values.1,
            detail: values.2,
            estimatedTokens: estimatedTokens(for: rendered),
            groupID: group?.id
        )
    }

    private nonisolated static func groupItem(
        _ group: TranscriptToolExchangeGroup
    ) -> TranscriptContextItem {
        TranscriptContextItem(
            id: group.id,
            kind: .toolExchange,
            title: group.title,
            detail: group.toolNames.joined(separator: ", "),
            estimatedTokens: group.estimatedTokens,
            groupID: group.id
        )
    }

    private nonisolated static func render(_ entry: Transcript.Entry) -> String {
        switch entry {
        case .instructions(let instructions):
            return text(instructions.segments)
        case .prompt(let prompt):
            return text(prompt.segments)
        case .response(let response):
            return text(response.segments)
        case .reasoning(let reasoning):
            return text(reasoning.segments)
        case .toolCalls(let calls):
            return calls.map { "\($0.toolName)(\($0.arguments))" }.joined(separator: "\n")
        case .toolOutput(let output):
            return "\(output.toolName): \(text(output.segments))"
        @unknown default:
            return ""
        }
    }

    private nonisolated static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            guard case .text(let value) = segment else { return nil }
            return value.content
        }
        .joined(separator: "\n")
    }

    private nonisolated static func estimatedTokens(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, (text.count + 3) / 4)
    }

    private nonisolated static func displayValues(
        for kind: ChatBlockKind
    ) -> (kind: TranscriptContextItem.Kind, title: String) {
        switch kind {
        case .user: (.user, "User")
        case .assistant: (.assistant, "Assistant")
        case .reasoning: (.reasoning, "Reasoning")
        case .tool: (.toolOutput, "Tool result")
        case .approval: (.unknown, "Approval")
        case .review: (.unknown, "Review")
        case .compaction: (.unknown, "Context compaction")
        case .diffPatch: (.toolOutput, "Edited files")
        case .gitCommit: (.toolOutput, "Git commit")
        case .gitStatus: (.toolOutput, "Git status")
        case .productGuide: (.toolOutput, "Product guide")
        case .workspaceListing: (.toolOutput, "Workspace listing")
        case .pluginWidget: (.toolOutput, "Plugin result")
        case .editorialPublication: (.toolOutput, "Published document")
        }
    }
}
