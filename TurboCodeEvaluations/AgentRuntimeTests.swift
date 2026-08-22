import Foundation
import Observation
import Testing
@testable import TurboCode

@Suite("Agent runtime")
@MainActor
struct AgentRuntimeTests {
    @Test("Runtime submit preserves every configured backend identity")
    func submitPreservesBackendIdentity() async {
        for backend in ModelBackend.allCases {
            let runtime = AgentRuntime(backend: backend)
            let request = TurnRequest(
                id: TurnID(rawValue: "backend-\(backend.rawValue)"),
                prompt: "Run the provider-neutral boundary test.",
                backend: backend,
                modelName: "configured-test-model",
                workspaceRoot: "/workspace"
            )

            #expect(await runtime.apply(.submit(request)))
            let snapshot = await runtime.snapshot
            #expect(snapshot.backend == backend)
            #expect(snapshot.turn?.id == request.id)
        }
    }

    @Test("AgentRuntime accepts a native submit command")
    func acceptsSubmitCommand() async {
        let turnID = TurnID(rawValue: "agent-runtime-submit")
        let runtime = AgentRuntime()
        let request = TurnRequest(
            id: turnID,
            prompt: "Inspect the workspace",
            backend: .foundationApple,
            modelName: "test-model",
            workspaceRoot: "/workspace"
        )

        #expect(await runtime.apply(.submit(request)))
        #expect(await runtime.currentTurnState?.id == turnID)
        #expect(await runtime.currentTurnState?.phase == .accepted)
        #expect(await runtime.apply(.cancel(turnID: turnID)))
        #expect(await runtime.currentTurnState?.phase == .cancelled)
        #expect(await !runtime.owns(turnID))
    }

    @Test("Runtime start is idempotent and rejects a competing live turn")
    func guardsTurnAdmission() async {
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

        #expect(await runtime.apply(.started(request)))
        #expect(
            await runtime.apply(
                .phaseChanged(
                    turnID: request.id,
                    phase: .preparing,
                    at: Date()
                )
            )
        )
        #expect(await runtime.apply(.started(request)))
        #expect(await !runtime.apply(.started(competing)))
        #expect(await runtime.currentTurnState?.id == request.id)
        #expect(await runtime.currentTurnState?.phase == .preparing)
    }

    @Test("Runtime events own tool, approval, and terminal lifecycle")
    func reducesNormalizedLifecycleEvents() async {
        let runtime = AgentRuntime()
        let turnID = TurnID(rawValue: "normalized-events")
        let request = TurnRequest(
            id: turnID,
            prompt: "Exercise the lifecycle",
            backend: .llamaServer,
            modelName: "test-model",
            workspaceRoot: "/workspace"
        )

        #expect(await runtime.apply(.started(request)))
        #expect(await runtime.apply(.phaseChanged(
            turnID: turnID,
            phase: .preparing,
            at: Date()
        )))
        #expect(await runtime.apply(.phaseChanged(
            turnID: turnID,
            phase: .streaming,
            at: Date()
        )))
        #expect(await runtime.apply(.toolStarted(
            ToolCall(id: "tool", turnID: turnID, name: "read_file")
        )))
        #expect(await runtime.currentTurnState?.phase == .toolExecuting)
        #expect(await runtime.apply(.approvalRequested(
            Approval(
                id: "approval",
                turnID: turnID,
                toolCallID: "tool",
                operation: "read",
                summary: "Read one file"
            )
        )))
        #expect(await runtime.currentTurnState?.phase == .awaitingApproval)
        #expect(await runtime.apply(.toolFinished(
            ToolResult(id: "tool", turnID: turnID, status: .succeeded)
        )))
        #expect(await runtime.apply(.phaseChanged(
            turnID: turnID,
            phase: .settling,
            at: Date()
        )))
        #expect(await runtime.apply(.completed(
            turnID: turnID,
            outcome: .succeeded,
            at: Date()
        )))
        #expect(await runtime.currentTurnState?.phase == .completed)
    }

    @Test("Runtime context commands replace only a settled turn")
    func contextCommandsPublishThreadAndBackend() async {
        let runtime = AgentRuntime()
        let turnID = TurnID(rawValue: "context-command-turn")
        await runtime.begin(
            TurnRequest(
                id: turnID,
                prompt: "Switch context",
                backend: .foundationApple,
                modelName: "test-model",
                workspaceRoot: "/workspace"
            )
        )

        #expect(await !runtime.apply(.switchThread(threadID: "new-thread")))
        #expect(await runtime.apply(.cancel(turnID: turnID)))
        #expect(await runtime.apply(.switchThread(threadID: "new-thread")))
        var snapshot = await runtime.snapshot
        #expect(snapshot.activeThreadID == "new-thread")
        #expect(snapshot.turn == nil)

        #expect(
            await runtime.apply(
                .switchBackend(
                    RuntimeBackendSelection(backend: .llamaServer)
                )
            )
        )
        snapshot = await runtime.snapshot
        #expect(snapshot.backend == .llamaServer)
        #expect(await runtime.apply(.restore(threadID: "restored-thread")))
        snapshot = await runtime.snapshot
        #expect(snapshot.activeThreadID == "restored-thread")
    }

    @Test("AgentRuntime publishes lifecycle snapshots without owning provider work")
    func publishesLifecycleSnapshots() async {
        let start = Date(timeIntervalSince1970: 500)
        let turnID = TurnID(rawValue: "agent-runtime-turn")
        let runtime = AgentRuntime(
            activeThreadID: "thread-1",
            backend: .foundationApple
        )

        await runtime.begin(
            TurnRequest(
                id: turnID,
                prompt: "Inspect the workspace",
                backend: .llamaServer,
                modelName: "configured-model",
                workspaceRoot: "/workspace",
                createdAt: start
            )
        )
        let acceptedSnapshot = await runtime.snapshot
        #expect(acceptedSnapshot.activeThreadID == "thread-1")
        #expect(acceptedSnapshot.backend == .llamaServer)
        #expect(acceptedSnapshot.turn?.phase == .accepted)

        let advanced = await runtime.advance(
            to: .preparing,
            turnID: turnID,
            at: Date(timeIntervalSince1970: 501)
        )
        #expect(advanced)
        #expect(await runtime.currentTurnState?.phase == .preparing)
        #expect(await runtime.owns(turnID))
    }

    @Test("AgentRuntime rejects late completion after terminal state")
    func rejectsLateCompletion() async {
        let turnID = TurnID(rawValue: "agent-runtime-terminal")
        let runtime = AgentRuntime()
        await runtime.begin(
            TurnRequest(
                id: turnID,
                prompt: "Complete the turn",
                backend: .foundationApple,
                modelName: "test-model",
                workspaceRoot: "/workspace",
                createdAt: Date(timeIntervalSince1970: 600)
            )
        )
        _ = await runtime.advance(
            to: .preparing,
            turnID: turnID,
            at: Date(timeIntervalSince1970: 601)
        )

        let finished = await runtime.finish(
            with: .cancelled(reason: "user"),
            turnID: turnID,
            at: Date(timeIntervalSince1970: 602)
        )
        let lateFinish = await runtime.finish(
            with: .succeeded,
            turnID: turnID,
            at: Date(timeIntervalSince1970: 603)
        )

        #expect(finished)
        #expect(!lateFinish)
        #expect(await runtime.snapshot.turn?.phase == .cancelled)
        #expect(await !runtime.owns(turnID))
    }

    @Test("AgentRuntime keeps nested transition barriers closed")
    func nestsQuiescenceBarriers() async {
        let runtime = AgentRuntime()

        await runtime.beginQuiescence()
        await runtime.beginQuiescence()
        #expect(await runtime.snapshot.isQuiescing)

        await runtime.endQuiescence()
        #expect(await runtime.snapshot.isQuiescing)

        await runtime.endQuiescence()
        #expect(await !runtime.snapshot.isQuiescing)

        // An unmatched end must not underflow or reopen a future barrier.
        await runtime.endQuiescence()
        #expect(await !runtime.snapshot.isQuiescing)
    }

    @Test("AgentRuntime creates, cancels, awaits, and releases its operation")
    func ownsOperationHandleThroughCancellation() async {
        let turnID = TurnID(rawValue: "agent-runtime-operation")
        let (snapshots, continuation) = AsyncStream.makeStream(
            of: RuntimeSnapshot.self
        )
        let runtime = AgentRuntime { snapshot in
            continuation.yield(snapshot)
        }
        var iterator = snapshots.makeAsyncIterator()
        let execution = Task {
            await runtime.runOperation(turnID: turnID) {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        let activeSnapshot = await iterator.next()

        #expect(activeSnapshot?.hasActiveOperation == true)
        #expect(await runtime.ownsOperation(turnID))

        await runtime.cancelAndWaitForOperation()
        _ = await execution.value

        #expect(await !runtime.hasActiveOperation)
        #expect(await !runtime.ownsOperation(turnID))
        continuation.finish()
    }

    @Test("Idle waiters resume when the owned operation settles")
    func resumesIdleWaitersWithoutPolling() async {
        let turnID = TurnID(rawValue: "agent-runtime-idle-waiter")
        let (snapshots, continuation) = AsyncStream.makeStream(
            of: RuntimeSnapshot.self
        )
        let runtime = AgentRuntime { snapshot in
            continuation.yield(snapshot)
        }
        var iterator = snapshots.makeAsyncIterator()
        let execution = Task {
            await runtime.runOperation(turnID: turnID) {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        #expect(await iterator.next()?.hasActiveOperation == true)

        let waiter = Task {
            await runtime.waitUntilIdle()
            return await runtime.hasActiveOperation
        }
        await Task.yield()
        await runtime.cancelAndWaitForOperation()

        #expect(await waiter.value == false)
        _ = await execution.value
        continuation.finish()
    }

    @Test("Concurrent submissions admit exactly one live turn")
    func serializesCompetingSubmissions() async {
        let runtime = AgentRuntime()
        let requests = [
            TurnRequest(
                id: TurnID(rawValue: "concurrent-a"),
                prompt: "First contender",
                backend: .foundationApple,
                modelName: "test-model",
                workspaceRoot: "/workspace"
            ),
            TurnRequest(
                id: TurnID(rawValue: "concurrent-b"),
                prompt: "Second contender",
                backend: .llamaServer,
                modelName: "test-model",
                workspaceRoot: "/workspace"
            )
        ]

        let admissions = await withTaskGroup(of: Bool.self) { group in
            for request in requests {
                group.addTask {
                    await runtime.apply(.submit(request))
                }
            }
            var values: [Bool] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        let admittedTurnID = await runtime.currentTurnState?.id

        #expect(admissions.filter { $0 }.count == 1)
        #expect(requests.map(\.id).contains(admittedTurnID))
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
        #expect(await !runtime.hasActiveOperation)
        #expect(await !runtime.ownsOperation(turnID))

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
