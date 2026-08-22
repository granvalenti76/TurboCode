import Foundation
import Testing
@testable import TurboCode

@Suite("Agent runtime")
@MainActor
struct AgentRuntimeTests {
    @Test("AgentRuntime publishes lifecycle snapshots without owning provider work")
    func publishesLifecycleSnapshots() {
        let start = Date(timeIntervalSince1970: 500)
        let turnID = TurnID(rawValue: "agent-runtime-turn")
        let runtime = AgentRuntime(
            activeThreadID: "thread-1",
            backend: .foundationApple
        )

        runtime.begin(
            TurnRequest(
                id: turnID,
                prompt: "Inspect the workspace",
                backend: .llamaServer,
                modelName: "configured-model",
                workspaceRoot: "/workspace",
                createdAt: start
            )
        )
        #expect(runtime.snapshot.activeThreadID == "thread-1")
        #expect(runtime.snapshot.backend == .llamaServer)
        #expect(runtime.snapshot.turn?.phase == .accepted)

        let advanced = runtime.advance(
            to: .preparing,
            turnID: turnID,
            at: Date(timeIntervalSince1970: 501)
        )
        #expect(advanced)
        #expect(runtime.currentTurnState?.phase == .preparing)
        #expect(runtime.owns(turnID))
    }

    @Test("AgentRuntime rejects late completion after terminal state")
    func rejectsLateCompletion() {
        let turnID = TurnID(rawValue: "agent-runtime-terminal")
        let runtime = AgentRuntime()
        runtime.begin(
            TurnRequest(
                id: turnID,
                prompt: "Complete the turn",
                backend: .foundationApple,
                modelName: "test-model",
                workspaceRoot: "/workspace",
                createdAt: Date(timeIntervalSince1970: 600)
            )
        )
        _ = runtime.advance(
            to: .preparing,
            turnID: turnID,
            at: Date(timeIntervalSince1970: 601)
        )

        let finished = runtime.finish(
            with: .cancelled(reason: "user"),
            turnID: turnID,
            at: Date(timeIntervalSince1970: 602)
        )
        let lateFinish = runtime.finish(
            with: .succeeded,
            turnID: turnID,
            at: Date(timeIntervalSince1970: 603)
        )

        #expect(finished)
        #expect(!lateFinish)
        #expect(runtime.snapshot.turn?.phase == .cancelled)
        #expect(!runtime.owns(turnID))
    }
}
