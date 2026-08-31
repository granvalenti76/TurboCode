import Testing
@testable import TurboCode

@Suite("Backend event ingress")
struct BackendEventIngressTests {
    @Test("Current streaming events are admitted for every provider backend")
    @MainActor
    func providerBackendsShareTheExecutorNeutralGate() async {
        let backends: [ModelBackend] = [
            .foundationApple,
            .llamaServer,
            .premium, // DeepSeek's configured remote profile.
            .codex
        ]

        for backend in backends {
            let turnID = TurnID(rawValue: "ingress-\(backend.rawValue)")
            let runtime = AgentRuntime()
            let capture = IngressDeliveryCapture()
            let ingress = BackendEventIngress(
                turnID: turnID,
                runtime: runtime,
                delivery: { event in
                    capture.events.append(event)
                }
            )
            let request = TurnRequest(
                id: turnID,
                prompt: "stream",
                backend: backend,
                modelName: "fixture",
                workspaceRoot: "/workspace"
            )

            #expect(await runtime.apply(.started(request)))
            await ingress.receive(
                .assistantTextChanged(turnID: turnID, text: "current")
            )
            await ingress.receive(
                .assistantTextChanged(
                    turnID: TurnID(rawValue: "stale-\(backend.rawValue)"),
                    text: "stale"
                )
            )
            await ingress.flush()

            #expect(capture.events.count == 1)
            guard case .assistantTextChanged(_, let text) = capture.events.first else {
                Issue.record("Expected the current assistant event to be delivered")
                continue
            }
            #expect(text == "current")

            await ingress.close()
            await ingress.receive(
                .assistantTextChanged(turnID: turnID, text: "after close")
            )
            #expect(capture.events.count == 1)
        }
    }

    @Test("Newest text is coalesced and flushed before a tool event")
    @MainActor
    func coalescingPreservesSemanticOrder() async {
        let turnID = TurnID(rawValue: "ingress-order")
        let runtime = AgentRuntime()
        let capture = IngressDeliveryCapture()
        let ingress = BackendEventIngress(
            turnID: turnID,
            runtime: runtime,
            delivery: { event in
                capture.events.append(event)
            },
            coalescingNanoseconds: 1_000_000_000
        )
        #expect(await runtime.apply(.started(TurnRequest(
            id: turnID,
            prompt: "stream",
            backend: .llamaServer,
            modelName: "fixture",
            workspaceRoot: "/workspace"
        ))))
        await ingress.receive(
            .phaseChanged(turnID: turnID, phase: .preparing, at: .now)
        )
        await ingress.receive(
            .phaseChanged(turnID: turnID, phase: .streaming, at: .now)
        )
        capture.events.removeAll()

        await ingress.receive(
            .assistantTextChanged(turnID: turnID, text: "partial")
        )
        await ingress.receive(
            .assistantTextChanged(turnID: turnID, text: "complete")
        )
        #expect(capture.events.isEmpty)

        await ingress.receive(.toolStarted(ToolCall(
            id: "tool",
            turnID: turnID,
            name: "read_file"
        )))

        #expect(capture.events.count == 2)
        guard case .assistantTextChanged(_, let text) = capture.events[0] else {
            Issue.record("Expected coalesced assistant text before tool start")
            return
        }
        #expect(text == "complete")
        guard case .toolStarted = capture.events[1] else {
            Issue.record("Expected tool start after the text flush")
            return
        }
    }
}

@MainActor
private final class IngressDeliveryCapture {
    var events: [AgentRuntimeEvent] = []
}
