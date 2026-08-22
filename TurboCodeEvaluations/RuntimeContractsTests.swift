import Foundation
import Testing
@testable import TurboCode

@Suite("Runtime contracts")
struct RuntimeContractsTests {
    @Test("A turn accepts only the ordered lifecycle transitions")
    func validatesTurnTransitions() {
        let accepted = TurnPhase.accepted
        #expect(accepted.canTransition(to: .preparing))
        #expect(accepted.canTransition(to: .cancelled))
        #expect(!accepted.canTransition(to: .streaming))
        #expect(!TurnPhase.completed.canTransition(to: .preparing))
    }

    @Test("Turn state rejects stale or invalid terminal updates")
    func rejectsInvalidStateUpdates() {
        let start = Date(timeIntervalSince1970: 100)
        let state = TurnState(id: TurnID(rawValue: "turn-1"), startedAt: start)
        let preparing = state.transitioning(
            to: .preparing,
            at: Date(timeIntervalSince1970: 101)
        )
        #expect(preparing?.phase == .preparing)
        #expect(preparing?.transitioning(to: .completed, at: Date()) == nil)

        let failed = preparing?.finishing(
            with: .failed(
                TurnFailure(code: "provider", message: "Unavailable")
            ),
            at: Date(timeIntervalSince1970: 102)
        )
        #expect(failed?.phase == .failed)
        #expect(failed?.outcome != nil)
        #expect(failed?.finishing(with: .succeeded, at: Date()) == nil)
    }

    @Test("Runtime measurements clamp invalid values")
    func clampsMeasurements() {
        let usage = Usage(
            inputTokens: -10,
            cachedInputTokens: -3,
            outputTokens: 12
        )
        #expect(usage.inputTokens == 0)
        #expect(usage.cachedInputTokens == 0)
        #expect(usage.totalTokens == 12)

        let context = ContextUsage(usedTokens: -4, contextSize: 0)
        #expect(context.usedTokens == 0)
        #expect(context.contextSize == 1)
        #expect(context.fraction == 0)
    }

    @Test("Every normalized event exposes its owning turn")
    func exposesEventTurnID() {
        let id = TurnID(rawValue: "turn-2")
        let request = TurnRequest(
            id: id,
            prompt: "Inspect the project",
            backend: .foundationApple,
            modelName: "On-device",
            workspaceRoot: "/workspace"
        )
        let call = ToolCall(
            id: "call-1",
            turnID: id,
            name: "read_file"
        )

        #expect(AgentRuntimeEvent.started(request).turnID == id)
        #expect(AgentRuntimeEvent.toolStarted(call).turnID == id)
        #expect(
            AgentRuntimeEvent.completed(
                turnID: id,
                outcome: .succeeded,
                at: Date()
            ).turnID == id
        )
    }

    @Test("Worker envelopes preserve parent turn ownership without changing tool input")
    func preservesWorkerParentTurnOwnership() throws {
        let parent = TurnID(rawValue: "parent-turn")
        let envelope = try AgentTaskEnvelope(
            taskID: "task-1",
            attemptID: "attempt-1",
            goal: "Inspect the workspace.",
            acceptanceCriteria: ["Return a result."],
            parentTurnID: parent
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(
            AgentTaskEnvelope.self,
            from: data
        )

        #expect(decoded.parentTurnID == parent)
        #expect(decoded.goal == envelope.goal)
        #expect(decoded.mode == .coding)
    }

    @Test("Independent task completions reject stale and cancelled results")
    func guardsIndependentTaskCompletion() {
        let active = TurnID(rawValue: "active")
        let stale = TurnID(rawValue: "stale")

        #expect(
            TurnCompletionPolicy.accepts(
                turnID: active,
                activeTurnID: active,
                isCancelled: false
            )
        )
        #expect(
            !TurnCompletionPolicy.accepts(
                turnID: stale,
                activeTurnID: active,
                isCancelled: false
            )
        )
        #expect(
            !TurnCompletionPolicy.accepts(
                turnID: active,
                activeTurnID: active,
                isCancelled: true
            )
        )
    }
}
