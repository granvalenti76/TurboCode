import Foundation
import Observation
import Testing
@testable import TurboCode

@Suite("Agent runtime")
@MainActor
struct AgentRuntimeTests {
    @Test("Runtime submit preserves every configured backend identity")
    func submitPreservesBackendIdentity() {
        for backend in ModelBackend.allCases {
            let runtime = AgentRuntime(backend: backend)
            let request = TurnRequest(
                id: TurnID(rawValue: "backend-\(backend.rawValue)"),
                prompt: "Run the provider-neutral boundary test.",
                backend: backend,
                modelName: "configured-test-model",
                workspaceRoot: "/workspace"
            )

            #expect(runtime.apply(.submit(request)))
            #expect(runtime.snapshot.backend == backend)
            #expect(runtime.snapshot.turn?.id == request.id)
        }
    }

    @Test("AgentRuntime accepts a native submit command")
    func acceptsSubmitCommand() {
        let turnID = TurnID(rawValue: "agent-runtime-submit")
        let runtime = AgentRuntime()
        let request = TurnRequest(
            id: turnID,
            prompt: "Inspect the workspace",
            backend: .foundationApple,
            modelName: "test-model",
            workspaceRoot: "/workspace"
        )

        #expect(runtime.apply(.submit(request)))
        #expect(runtime.currentTurnState?.id == turnID)
        #expect(runtime.currentTurnState?.phase == .accepted)
        #expect(runtime.apply(.cancel(turnID: turnID)))
        #expect(runtime.currentTurnState?.phase == .cancelled)
        #expect(!runtime.owns(turnID))
    }

    @Test("Runtime start is idempotent and rejects a competing live turn")
    func guardsTurnAdmission() {
        let runtime = AgentRuntime()
        let request = TurnRequest(
            id: TurnID(rawValue: "admitted-turn"),
            prompt: "Keep this turn",
            backend: .foundationApple,
            modelName: "test-model",
            workspaceRoot: "/workspace"
        )
        let competing = TurnRequest(
            id: TurnID(rawValue: "competing-turn"),
            prompt: "Replace the live turn",
            backend: .codex,
            modelName: "test-codex",
            workspaceRoot: "/workspace"
        )

        #expect(runtime.apply(.started(request)))
        #expect(
            runtime.apply(
                .phaseChanged(
                    turnID: request.id,
                    phase: .preparing,
                    at: Date()
                )
            )
        )
        #expect(runtime.apply(.started(request)))
        #expect(!runtime.apply(.started(competing)))
        #expect(runtime.currentTurnState?.id == request.id)
        #expect(runtime.currentTurnState?.phase == .preparing)
    }

    @Test("Runtime events own tool, approval, and terminal lifecycle")
    func reducesNormalizedLifecycleEvents() {
        let runtime = AgentRuntime()
        let turnID = TurnID(rawValue: "normalized-events")
        let request = TurnRequest(
            id: turnID,
            prompt: "Exercise the lifecycle",
            backend: .llamaServer,
            modelName: "test-model",
            workspaceRoot: "/workspace"
        )

        #expect(runtime.apply(.started(request)))
        #expect(runtime.apply(.phaseChanged(
            turnID: turnID,
            phase: .preparing,
            at: Date()
        )))
        #expect(runtime.apply(.phaseChanged(
            turnID: turnID,
            phase: .streaming,
            at: Date()
        )))
        #expect(runtime.apply(.toolStarted(
            ToolCall(id: "tool", turnID: turnID, name: "read_file")
        )))
        #expect(runtime.currentTurnState?.phase == .toolExecuting)
        #expect(runtime.apply(.approvalRequested(
            Approval(
                id: "approval",
                turnID: turnID,
                toolCallID: "tool",
                operation: "read",
                summary: "Read one file"
            )
        )))
        #expect(runtime.currentTurnState?.phase == .awaitingApproval)
        #expect(runtime.apply(.toolFinished(
            ToolResult(id: "tool", turnID: turnID, status: .succeeded)
        )))
        #expect(runtime.apply(.phaseChanged(
            turnID: turnID,
            phase: .settling,
            at: Date()
        )))
        #expect(runtime.apply(.completed(
            turnID: turnID,
            outcome: .succeeded,
            at: Date()
        )))
        #expect(runtime.currentTurnState?.phase == .completed)
    }

    @Test("Runtime context commands replace only a settled turn")
    func contextCommandsPublishThreadAndBackend() {
        let runtime = AgentRuntime()
        let turnID = TurnID(rawValue: "context-command-turn")
        runtime.begin(
            TurnRequest(
                id: turnID,
                prompt: "Switch context",
                backend: .foundationApple,
                modelName: "test-model",
                workspaceRoot: "/workspace"
            )
        )

        #expect(!runtime.apply(.switchThread(threadID: "new-thread")))
        #expect(runtime.apply(.cancel(turnID: turnID)))
        #expect(runtime.apply(.switchThread(threadID: "new-thread")))
        #expect(runtime.snapshot.activeThreadID == "new-thread")
        #expect(runtime.snapshot.turn == nil)

        #expect(
            runtime.apply(
                .switchBackend(
                    RuntimeBackendSelection(backend: .llamaServer)
                )
            )
        )
        #expect(runtime.snapshot.backend == .llamaServer)
        #expect(runtime.apply(.restore(threadID: "restored-thread")))
        #expect(runtime.snapshot.activeThreadID == "restored-thread")
    }

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

    @Test("AgentRuntime keeps nested transition barriers closed")
    func nestsQuiescenceBarriers() {
        let runtime = AgentRuntime()

        runtime.beginQuiescence()
        runtime.beginQuiescence()
        #expect(runtime.snapshot.isQuiescing)

        runtime.endQuiescence()
        #expect(runtime.snapshot.isQuiescing)

        runtime.endQuiescence()
        #expect(!runtime.snapshot.isQuiescing)

        // An unmatched end must not underflow or reopen a future barrier.
        runtime.endQuiescence()
        #expect(!runtime.snapshot.isQuiescing)
    }

    @Test("AgentRuntime creates, cancels, awaits, and releases its operation")
    func ownsOperationHandleThroughCancellation() async {
        let turnID = TurnID(rawValue: "agent-runtime-operation")
        let runtime = AgentRuntime()
        let execution = Task {
            await runtime.runOperation(turnID: turnID) {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        await Task.yield()

        #expect(runtime.hasActiveOperation)
        #expect(runtime.ownsOperation(turnID))

        await runtime.cancelAndWaitForOperation()
        _ = await execution.value

        #expect(!runtime.hasActiveOperation)
        #expect(!runtime.ownsOperation(turnID))
    }

    @Test("Idle waiters resume when the owned operation settles")
    func resumesIdleWaitersWithoutPolling() async {
        let turnID = TurnID(rawValue: "agent-runtime-idle-waiter")
        let runtime = AgentRuntime()
        let execution = Task {
            await runtime.runOperation(turnID: turnID) {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        await Task.yield()

        let waiter = Task {
            await runtime.waitUntilIdle()
            return runtime.hasActiveOperation
        }
        await Task.yield()
        await runtime.cancelAndWaitForOperation()

        #expect(await waiter.value == false)
        _ = await execution.value
    }

    @Test("Ancillary work starts only after runtime ownership is released")
    func releasesOperationBeforeAncillaryWork() async {
        let turnID = TurnID(rawValue: "agent-runtime-ancillary-work")
        let runtime = AgentRuntime()
        let (ancillaryStarted, continuation) = AsyncStream.makeStream(of: Void.self)
        let execution = Task { @MainActor in
            await runtime.runOperation(
                turnID: turnID,
                operation: {},
                afterRelease: {
                    continuation.yield()
                    try? await Task.sleep(for: .seconds(60))
                }
            )
        }
        var iterator = ancillaryStarted.makeAsyncIterator()

        _ = await iterator.next()

        // A stuck optional title generator may outlive the response, but it
        // must not keep Stop visible or reject the next provider operation.
        #expect(!runtime.hasActiveOperation)
        #expect(!runtime.ownsOperation(turnID))

        execution.cancel()
        continuation.finish()
        _ = await execution.value
    }

    @Test("ChatStore busy projection observes runtime ownership changes")
    func busyProjectionInvalidatesForRuntimeOperation() async {
        let store = ChatStore(
            conversationRepository: RuntimeObservationConversationRepository()
        )
        let turnID = TurnID(rawValue: "observable-runtime-operation")
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        var iterator = changes.makeAsyncIterator()

        withObservationTracking {
            _ = store.busy
        } onChange: {
            continuation.yield()
        }

        let execution = Task { @MainActor in
            await store.agentRuntime.runOperation(turnID: turnID) {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        _ = await iterator.next()
        #expect(store.busy)

        // Observation tracking is one-shot. Register again while the operation
        // is active so the release edge must invalidate the same UI projection.
        withObservationTracking {
            _ = store.busy
        } onChange: {
            continuation.yield()
        }

        await store.agentRuntime.cancelAndWaitForOperation()
        _ = await iterator.next()
        #expect(!store.busy)

        continuation.finish()
        _ = await execution.value
    }
}

/// Keeps the Observation regression isolated from the user's session files;
/// the test exercises only runtime ownership and the facade's computed view.
private struct RuntimeObservationConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}
