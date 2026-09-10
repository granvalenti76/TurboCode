import Foundation
import Testing
@testable import TurboCode

@Suite("ACP event projector")
struct ACPEventProjectorTests {
    @Test("cumulative assistant snapshots become non-duplicated chunks")
    func assistantDeltas() async {
        let projector = ACPEventProjector()
        let turnID = TurnID(rawValue: "turn-1")
        let first = await projector.update(
            for: .assistantTextChanged(turnID: turnID, text: "Hello"),
            sessionID: "session-1"
        )
        let second = await projector.update(
            for: .assistantTextChanged(turnID: turnID, text: "Hello world"),
            sessionID: "session-1"
        )

        #expect(first?.update.objectValue?["content"]?.objectValue?["text"] == .string("Hello"))
        #expect(second?.update.objectValue?["content"]?.objectValue?["text"] == .string(" world"))
        #expect(first?.update.objectValue?["messageId"] == second?.update.objectValue?["messageId"])
    }

    @Test("tool results preserve completion status and output")
    func toolResult() async {
        let projector = ACPEventProjector()
        let turnID = TurnID(rawValue: "turn-1")
        let result = ToolResult(
            id: "call-1",
            turnID: turnID,
            status: .failed,
            output: "",
            errorMessage: "Permission denied"
        )

        let update = await projector.update(
            for: .toolFinished(result),
            sessionID: "session-1"
        )
        let payload = update?.update.objectValue
        #expect(payload?["sessionUpdate"] == .string("tool_call_update"))
        #expect(payload?["status"] == .string("failed"))
        #expect(
            payload?["content"]?.arrayValue?.first?.objectValue?["content"]?.objectValue?["text"]
                == .string("Permission denied")
        )
    }

    @Test("reasoning and approvals are not advertised as unsupported updates")
    func unsupportedEventsRemainSilent() async {
        let projector = ACPEventProjector()
        let turnID = TurnID(rawValue: "turn-1")
        #expect(
            await projector.update(
                for: .reasoningTextChanged(turnID: turnID, text: "internal"),
                sessionID: "session-1"
            ) == nil
        )
    }
}
