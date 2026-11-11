import Foundation
import FoundationModelsUtilities
import Testing
@testable import TurboCode

@MainActor
@Suite("Streamed tool-call relay")
struct ToolCallStreamRelayTests {
    @Test("Fragments reach the sink in order and rebuild the arguments")
    func fragmentsRebuildArgumentsInOrder() async {
        let relay = ReasoningStreamRelay()
        let recorder = ToolCallUpdateRecorder()
        let registrationID = await relay.installToolCallSink { updates in
            recorder.updates.append(contentsOf: updates)
        }
        let streamID = UUID()

        for fragment in ["{\"command\":", "\"ls", " -la\"}"] {
            await relay.publishToolCall(
                streamID: streamID,
                index: 0,
                id: "call_1",
                name: "vm_exec",
                argumentsDelta: fragment
            )
        }
        await relay.finishToolCalls(streamID: streamID)
        await waitUntil { recorder.updates.last?.isComplete == true }

        #expect(recorder.updates.allSatisfy { $0.registrationID == registrationID })
        #expect(
            recorder.updates.map(\.argumentsDelta).joined() == "{\"command\":\"ls -la\"}"
        )
        #expect(recorder.updates.map(\.fragmentCount).reduce(0, +) == 3)
        #expect(recorder.updates.filter(\.isComplete).count == 1)
    }

    @Test("A removed sink receives nothing and leaves reasoning untouched")
    func removedSinkStopsDelivery() async {
        let relay = ReasoningStreamRelay()
        let recorder = ToolCallUpdateRecorder()
        let reasoningID = await relay.install { _ in }
        let registrationID = await relay.installToolCallSink { updates in
            recorder.updates.append(contentsOf: updates)
        }
        await relay.removeToolCallSink(registrationID)

        await relay.publishToolCall(
            streamID: UUID(),
            index: 0,
            id: "call_1",
            name: "vm_exec",
            argumentsDelta: "{}"
        )
        await relay.publish("thinking")
        await Task.yield()

        #expect(recorder.updates.isEmpty)
        #expect(await relay.textSnapshot() == "thinking")
        await relay.remove(reasoningID)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class ToolCallUpdateRecorder {
    var updates: [ReasoningStreamRelay.ToolCallUpdate] = []
}

@Suite("Live tool-call projection")
struct LiveToolCallProjectionTests {
    private let registrationID = UUID()

    private func update(
        stream: UUID,
        index: Int = 0,
        name: String = "vm_exec",
        delta: String = "",
        complete: Bool = false
    ) -> ReasoningStreamRelay.ToolCallUpdate {
        ReasoningStreamRelay.ToolCallUpdate(
            registrationID: registrationID,
            streamID: stream,
            index: index,
            id: "call",
            name: name,
            argumentsDelta: delta,
            fragmentCount: delta.isEmpty ? 0 : 1,
            isComplete: complete
        )
    }

    @Test("Each provider stream becomes a round and indexes stay separate")
    func streamsBecomeRounds() {
        let first = UUID()
        let second = UUID()
        var projection = LiveToolCallProjection()

        projection.apply([
            update(stream: first, index: 0, delta: "{\"a\":"),
            update(stream: first, index: 1, name: "vm_file", delta: "{}"),
            update(stream: first, index: 0, delta: "1}"),
            update(stream: first, index: 0, complete: true),
            update(stream: first, index: 1, name: "vm_file", complete: true)
        ])
        projection.apply([update(stream: second, index: 0, delta: "{\"a\":2")])

        #expect(projection.calls.map(\.round) == [1, 1, 2])
        #expect(projection.calls.map(\.arguments) == ["{\"a\":1}", "{}", "{\"a\":2"])
        #expect(projection.calls.map(\.phase) == [.written, .written, .writing])
        #expect(projection.calls[0].fragmentCount == 2)
    }

    @Test("A call left open when the turn ends is marked interrupted")
    func openCallIsInterruptedAtTurnEnd() {
        var projection = LiveToolCallProjection()
        projection.apply([update(stream: UUID(), delta: "{\"command\":\"sl")])
        projection.closeOpenCalls()

        #expect(projection.calls.map(\.phase) == [.interrupted])
    }

    @Test("Three identical calls in a row are reported as a possible loop")
    func identicalConsecutiveCallsAreReported() {
        var projection = LiveToolCallProjection()
        // Key order and spacing differ on purpose: the calls are still equal.
        let variants = [
            "{\"command\":\"ls\",\"timeout\":5}",
            "{ \"timeout\": 5, \"command\": \"ls\" }",
            "{\"command\":\"ls\",\"timeout\":5}"
        ]
        for (offset, arguments) in variants.enumerated() {
            let stream = UUID()
            projection.apply([
                update(stream: stream, delta: arguments),
                update(stream: stream, complete: true)
            ])
            let expected = offset == 2
                ? LiveToolCallRepetition(toolName: "vm_exec", count: 3)
                : nil
            #expect(projection.repetition == expected)
        }
    }

    @Test("A different call or an unfinished one does not count as a loop")
    func differentOrUnfinishedCallsAreNotALoop() {
        var projection = LiveToolCallProjection()
        for arguments in ["{\"command\":\"ls\"}", "{\"command\":\"ls\"}", "{\"command\":\"pwd\"}"] {
            let stream = UUID()
            projection.apply([
                update(stream: stream, delta: arguments),
                update(stream: stream, complete: true)
            ])
        }
        #expect(projection.repetition == nil)

        var unfinished = LiveToolCallProjection()
        for index in 0..<3 {
            let stream = UUID()
            unfinished.apply([update(stream: stream, delta: "{\"command\":\"ls\"}")])
            if index < 2 {
                unfinished.apply([update(stream: stream, complete: true)])
            }
        }
        #expect(unfinished.repetition == nil)
    }
}

@Suite("Tool-call argument formatting")
struct ToolCallArgumentFormatterTests {
    typealias Field = ToolCallArgumentFormatter.Field

    @Test("A complete object is split into decoded fields")
    func completeObject() {
        let fields = ToolCallArgumentFormatter.fields(
            from: "{\"command\":\"echo \\\"hi\\\"\\nls\",\"timeout\":30,\"env\":{\"A\":[1,2]}}"
        )
        #expect(fields == [
            Field(key: "command", value: "echo \"hi\"\nls", isComplete: true),
            Field(key: "timeout", value: "30", isComplete: true),
            Field(key: "env", value: "{\"A\":[1,2]}", isComplete: true)
        ])
    }

    @Test("The value being written is returned as an incomplete field")
    func partialStringValue() {
        let fields = ToolCallArgumentFormatter.fields(
            from: "{\"path\":\"/out/a.py\",\"content\":\"import os\\nprint("
        )
        #expect(fields == [
            Field(key: "path", value: "/out/a.py", isComplete: true),
            Field(key: "content", value: "import os\nprint(", isComplete: false)
        ])
    }

    @Test("Input cut inside a key, an escape or a number stays readable")
    func partialEdges() {
        #expect(ToolCallArgumentFormatter.fields(from: "") == [])
        #expect(ToolCallArgumentFormatter.fields(from: "{") == [])
        #expect(
            ToolCallArgumentFormatter.fields(from: "{\"comm")
                == [Field(key: "comm", value: "", isComplete: false)]
        )
        #expect(
            ToolCallArgumentFormatter.fields(from: "{\"a\":\"x\\")
                == [Field(key: "a", value: "x", isComplete: false)]
        )
        #expect(
            ToolCallArgumentFormatter.fields(from: "{\"n\":12")
                == [Field(key: "n", value: "12", isComplete: false)]
        )
        #expect(
            ToolCallArgumentFormatter.fields(from: "{\"u\":\"caf\\u00e9\"}")
                == [Field(key: "u", value: "café", isComplete: true)]
        )
    }

    @Test("Text that is not a JSON object is shown unmodified")
    func nonObjectInput() {
        #expect(
            ToolCallArgumentFormatter.fields(from: "ls -la")
                == [Field(key: "", value: "ls -la", isComplete: false)]
        )
    }
}
