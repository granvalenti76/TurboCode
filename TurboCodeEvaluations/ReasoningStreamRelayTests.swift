import FoundationModelsUtilities
import Testing

@MainActor
@Suite("Request-scoped reasoning relay")
struct ReasoningStreamRelayTests {
    @Test("Relay coalesces ordered deltas without dropping text")
    func coalescesOrderedRequestScopedDeltas() async {
        let relay = ReasoningStreamRelay()
        let recorder = RelayEventRecorder()
        let requestID = await relay.install { event in
            recorder.append(event)
        }

        await relay.publish("first")
        await relay.publish(" second")
        await waitForText(recorder, "first second")

        #expect(recorder.events.allSatisfy { $0.requestID == requestID })
        #expect(recorder.events.map(\.sequence) == recorder.events.map(\.sequence).sorted())
        #expect(recorder.events.map(\.delta).joined() == "first second")

        await relay.remove(requestID)
        await relay.publish(" stale")
        await Task.yield()
        #expect(recorder.events.count == 2)
    }

    @Test("Independent relays do not cross-route request events")
    func independentRelaysRemainIsolated() async {
        let firstRelay = ReasoningStreamRelay()
        let secondRelay = ReasoningStreamRelay()
        let firstRecorder = RelayEventRecorder()
        let secondRecorder = RelayEventRecorder()

        let firstRequestID = await firstRelay.install { event in
            firstRecorder.append(event)
        }
        let secondRequestID = await secondRelay.install { event in
            secondRecorder.append(event)
        }

        await firstRelay.publish("first")
        await secondRelay.publish("second")
        await waitForEvents(firstRecorder, count: 1)
        await waitForEvents(secondRecorder, count: 1)

        #expect(firstRecorder.events.first?.requestID == firstRequestID)
        #expect(secondRecorder.events.first?.requestID == secondRequestID)
        #expect(firstRecorder.events.first?.delta == "first")
        #expect(secondRecorder.events.first?.delta == "second")
    }

    private func waitForEvents(
        _ recorder: RelayEventRecorder,
        count: Int
    ) async {
        for _ in 0..<100 {
            if recorder.events.count >= count { return }
            await Task.yield()
        }
    }

    private func waitForText(
        _ recorder: RelayEventRecorder,
        _ text: String
    ) async {
        for _ in 0..<100 {
            if recorder.events.map(\.delta).joined() == text { return }
            await Task.yield()
        }
    }
}

@MainActor
private final class RelayEventRecorder {
    private(set) var events: [ReasoningStreamRelay.Event] = []

    func append(_ event: ReasoningStreamRelay.Event) {
        events.append(event)
    }
}
