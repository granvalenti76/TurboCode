import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@Suite("Transcript context projection")
struct TranscriptContextProjectionTests {
    @Test("Only complete tool exchanges become selectable groups")
    func groupsOnlyCompleteExchanges() {
        let transcript = Transcript(entries: fixtureTranscript())
        let presentation = TranscriptContextProjector.presentation(
            transcript: transcript,
            projection: .empty
        )

        #expect(presentation.groups.count == 1)
        #expect(presentation.groups.first?.toolCallIDs == ["call-complete"])
        #expect(presentation.turnBoundaries.map(\.id) == ["turn:1"])
        #expect(
            presentation.conversationItems.filter { $0.kind == .toolExchange }.count == 1
        )
        #expect(
            presentation.entryItems.filter { $0.kind == .toolCall }.count == 2
        )
    }

    @Test("Projection removes both sides of a selected exchange")
    func projectionRemovesCompleteExchange() throws {
        let transcript = Transcript(entries: fixtureTranscript())
        let group = try #require(
            TranscriptContextProjector.completedToolExchangeGroups(
                in: Array(transcript)
            ).first
        )
        let projection = TranscriptContextProjector.projection(
            selecting: [group.id],
            in: transcript
        )
        let materialized = projection.applying(to: Array(transcript))

        #expect(projection.excludedToolCallIDs == ["call-complete"])
        #expect(materialized.contains { entry in
            guard case .toolCalls(let calls) = entry else { return false }
            return calls.contains { $0.id == "call-complete" }
        } == false)
        #expect(materialized.contains { entry in
            guard case .toolOutput(let output) = entry else { return false }
            return output.id == "call-complete"
        } == false)
        // Incomplete calls stay untouched because a one-sided projection would
        // violate the provider transcript contract.
        #expect(materialized.contains { entry in
            guard case .toolCalls(let calls) = entry else { return false }
            return calls.contains { $0.id == "call-incomplete" }
        })
        #expect(materialized.contains { if case .reasoning = $0 { true } else { false } })
        #expect(materialized.contains { if case .response = $0 { true } else { false } })
    }

    @Test("Stored sessions round-trip projections and old data defaults empty")
    func persistenceIsBackwardCompatible() throws {
        let stored = StoredSession(
            title: "Context",
            projectName: "Fixture",
            transcript: Transcript(entries: fixtureTranscript()),
            contextProjection: TranscriptContextProjection(
                excludedToolCallIDs: ["call-complete"]
            )
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(stored)
        let decoded = try JSONDecoder().decode(StoredSession.self, from: data)
        #expect(decoded.contextProjection == stored.contextProjection)

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "contextProjection")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(StoredSession.self, from: legacyData)
        #expect(legacy.contextProjection == .empty)
    }

    @Test("Timeline fallback is read-only and keeps safe turn boundaries")
    func timelineFallbackIsReadOnly() {
        let presentation = TranscriptContextProjector.presentation(blocks: [
            ChatBlock(id: "user", kind: .user, text: "Question"),
            ChatBlock(id: "assistant", kind: .assistant, text: "Answer")
        ])

        #expect(presentation.hasTranscript)
        #expect(presentation.groups.isEmpty)
        #expect(presentation.excludedGroupIDs.isEmpty)
        #expect(presentation.turnBoundaries.map(\.id) == ["turn:1"])
    }

    private func fixtureTranscript() -> [Transcript.Entry] {
        let text: (String) -> Transcript.Segment = {
            .text(Transcript.TextSegment(content: $0))
        }
        let complete = Transcript.ToolCall(
            id: "call-complete",
            toolName: "read_file",
            arguments: GeneratedContent(properties: ["path": "README.md"])
        )
        let incomplete = Transcript.ToolCall(
            id: "call-incomplete",
            toolName: "search",
            arguments: GeneratedContent(properties: ["query": "TODO"])
        )
        return [
            .instructions(Transcript.Instructions(segments: [text("System")], toolDefinitions: [])),
            .prompt(Transcript.Prompt(segments: [text("Inspect the project")])),
            .reasoning(Transcript.Reasoning(segments: [text("I should inspect it.")])),
            .toolCalls(Transcript.ToolCalls([complete])),
            .toolOutput(Transcript.ToolOutput(
                id: complete.id,
                toolName: complete.toolName,
                segments: [text("Project contents")]
            )),
            .response(Transcript.Response(assetIDs: [], segments: [text("Inspection complete.")])),
            .toolCalls(Transcript.ToolCalls([incomplete]))
        ]
    }
}
