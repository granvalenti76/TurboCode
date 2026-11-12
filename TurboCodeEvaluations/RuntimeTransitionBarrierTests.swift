import Foundation
import Testing
@testable import TurboCode

/// Context changes arrive as independent unstructured tasks (one per sidebar
/// click). These tests pin the contract that they run one at a time, in
/// arrival order, and that no session save can snapshot a half-replaced
/// conversation.
@MainActor
@Suite("Runtime transition barrier")
struct RuntimeTransitionBarrierTests {
    @Test("Overlapping thread openings run one at a time in arrival order")
    func overlappingOpeningsAreSerialized() async throws {
        let gate = TransitionLoadGate()
        let repository = TransitionRepository(
            snapshots: ["x", "a", "b"].map(Self.snapshot(id:)),
            gatedLoadID: "a",
            gate: gate
        )
        let store = try Self.makeStore(repository: repository)
        await store.restoreSessions()
        await store.restoreSession(id: "x")
        await repository.resetLoadLog()

        let openA = Task { await store.openThread("a") }
        await gate.waitUntilEntered()
        let openB = Task { await store.openThread("b") }
        // Give the second opening every chance to overtake the suspended one.
        for _ in 0..<50 { await Task.yield() }

        #expect(await repository.loadLog == ["a"])
        #expect(store.activeThreadId == "x")

        await gate.release()
        await openA.value
        await openB.value

        #expect(await repository.loadLog == ["a", "b"])
        #expect(store.activeThreadId == "b")
        #expect(store.blocks.map(\.text) == ["Question b", "Answer b"])
    }

    @Test("Each conversation file keeps its own timeline across rapid switches")
    func rapidSwitchesDoNotCrossContaminateSavedSessions() async throws {
        let gate = TransitionLoadGate()
        let repository = TransitionRepository(
            snapshots: ["x", "a", "b"].map(Self.snapshot(id:)),
            gatedLoadID: "a",
            gate: gate
        )
        let store = try Self.makeStore(repository: repository)
        await store.restoreSessions()
        await store.restoreSession(id: "x")

        let openA = Task { await store.openThread("a") }
        await gate.waitUntilEntered()
        let openB = Task { await store.openThread("b") }
        // Let "b" register before "x" so the request order is deterministic.
        for _ in 0..<50 { await Task.yield() }
        let backToX = Task { await store.openThread("x") }
        await gate.release()
        await openA.value
        await openB.value
        await backToX.value

        for id in ["x", "a", "b"] {
            let saved = try #require(await repository.load(id: id))
            #expect(saved.conversation.id == id)
            #expect(saved.blocks.map(\.text) == ["Question \(id)", "Answer \(id)"])
        }
        #expect(store.activeThreadId == "x")
        // Returning to the starting thread was requested while it was still
        // active; it must be restored, not merely re-selected over "a".
        #expect(store.blocks.map(\.text) == ["Question x", "Answer x"])
    }

    @Test("A queued opening superseded by a later one is skipped")
    func supersededOpeningIsSkipped() async throws {
        let gate = TransitionLoadGate()
        let repository = TransitionRepository(
            snapshots: ["x", "a", "b", "c"].map(Self.snapshot(id:)),
            gatedLoadID: "a",
            gate: gate
        )
        let store = try Self.makeStore(repository: repository)
        await store.restoreSessions()
        await store.restoreSession(id: "x")
        await repository.resetLoadLog()

        let openA = Task { await store.openThread("a") }
        await gate.waitUntilEntered()
        let openB = Task { await store.openThread("b") }
        for _ in 0..<50 { await Task.yield() }
        let openC = Task { await store.openThread("c") }
        await gate.release()
        await openA.value
        await openB.value
        await openC.value

        // "a" was already being restored and completes; "b" never loads.
        #expect(await repository.loadLog == ["a", "c"])
        #expect(store.activeThreadId == "c")
        #expect(store.blocks.map(\.text) == ["Question c", "Answer c"])
    }

    @Test("A session save requested during a context change is skipped")
    func saveDuringContextChangeIsSkipped() async throws {
        let gate = TransitionLoadGate()
        let repository = TransitionRepository(
            snapshots: ["x", "a"].map(Self.snapshot(id:)),
            gatedLoadID: "a",
            gate: gate
        )
        let store = try Self.makeStore(repository: repository)
        await store.restoreSessions()
        await store.restoreSession(id: "x")

        let openA = Task { await store.openThread("a") }
        await gate.waitUntilEntered()
        let savesBefore = await repository.saveCount
        await store.persistSession(for: "x")
        #expect(await repository.saveCount == savesBefore)

        await gate.release()
        await openA.value

        // Saving works again once the replacement has completed.
        await store.persistSession(for: "a")
        #expect(await repository.saveCount == savesBefore + 1)
    }

    @Test("Admission stays closed across the handoff between queued changes")
    func admissionStaysClosedBetweenQueuedChanges() async throws {
        let gate = TransitionLoadGate()
        let repository = TransitionRepository(
            snapshots: ["x", "a", "b"].map(Self.snapshot(id:)),
            gatedLoadID: "a",
            gate: gate
        )
        let store = try Self.makeStore(repository: repository)
        await store.restoreSessions()
        await store.restoreSession(id: "x")

        let openA = Task { await store.openThread("a") }
        await gate.waitUntilEntered()
        let openB = Task { await store.openThread("b") }
        for _ in 0..<50 { await Task.yield() }
        let admittedWhileQueued = await store.agentRuntime.runOperation(
            turnID: TurnID(),
            operation: {}
        )
        #expect(!admittedWhileQueued)

        await gate.release()
        await openA.value
        await openB.value
        let admittedAfterwards = await store.agentRuntime.runOperation(
            turnID: TurnID(),
            operation: {}
        )
        #expect(admittedAfterwards)
    }

    private static func makeStore(
        repository: TransitionRepository
    ) throws -> ChatStore {
        let suiteName = "RuntimeTransitionBarrierTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return ChatStore(
            conversationRepository: repository,
            gitService: TransitionGitService(),
            workspaceDefaults: defaults
        )
    }

    private static func snapshot(id: String) -> ConversationSnapshot {
        ConversationSnapshot(
            conversation: Conversation(id: id, title: "Thread \(id)"),
            modelBackend: ModelBackend.foundationApple.rawValue,
            blocks: [
                ChatBlock(kind: .user, text: "Question \(id)"),
                ChatBlock(kind: .assistant, text: "Answer \(id)")
            ],
            transcript: nil
        )
    }
}

/// In-memory repository that can suspend the load of one conversation, which
/// holds a context change open inside its replacement operation.
private actor TransitionRepository: ConversationRepository {
    private var snapshots: [String: ConversationSnapshot]
    private let gatedLoadID: String
    private let gate: TransitionLoadGate
    private var gateUsed = false
    private(set) var loadLog: [String] = []
    private(set) var saveCount = 0

    init(
        snapshots: [ConversationSnapshot],
        gatedLoadID: String,
        gate: TransitionLoadGate
    ) {
        self.snapshots = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.conversation.id, $0) }
        )
        self.gatedLoadID = gatedLoadID
        self.gate = gate
    }

    func resetLoadLog() {
        loadLog.removeAll()
    }

    func save(_ snapshot: ConversationSnapshot) {
        saveCount += 1
        snapshots[snapshot.conversation.id] = snapshot
    }

    func load(id: String) async -> ConversationSnapshot? {
        loadLog.append(id)
        // Only the first gated load pauses; verification reads pass through.
        if id == gatedLoadID, !gateUsed {
            gateUsed = true
            await gate.pause()
        }
        return snapshots[id]
    }

    func list() -> [ConversationSnapshot] {
        Array(snapshots.values)
    }

    func delete(id: String) {
        snapshots[id] = nil
    }
}

private actor TransitionLoadGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor TransitionGitService: GitRepositoryServicing {
    func isGitRepository(at directory: URL) -> Bool { false }
    func currentBranch(at directory: URL) -> String? { nil }
    func allBranches(at directory: URL) -> [String] { [] }
    func undoCommit(expectedHash: String, at directory: URL) -> String? { nil }
    func checkout(branch: String, at directory: URL) -> Bool { false }
    func fetchChangedFiles(at url: URL) throws -> [GitFileStatus] { [] }
    func fetchDiff(for filePath: String, at url: URL) throws -> [DiffLine] { [] }
}
