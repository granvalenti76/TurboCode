import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Workspace lifecycle")
struct WorkspaceLifecycleTests {
    @Test("Switch and clear replace one complete workspace context")
    func switchAndClearReplaceWorkspaceContext() async throws {
        let suiteName = "WorkspaceLifecycleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let git = WorkspaceLifecycleGitService(
            isRepository: true,
            branch: "feature/runtime",
            branches: ["main", "feature/runtime"]
        )
        let store = ChatStore(
            conversationRepository: WorkspaceLifecycleRepository(),
            gitService: git,
            workspaceDefaults: defaults
        )
        store.workbenchStore.rightPanelMode = .activity

        await store.switchToWorkspace("/tmp/workspace-lifecycle")

        #expect(store.workspaceRoot == "/tmp/workspace-lifecycle")
        #expect(store.selectedProject == "workspace-lifecycle")
        #expect(store.isGitRepository)
        #expect(store.currentBranch == "feature/runtime")
        #expect(store.availableBranches == ["main", "feature/runtime"])
        #expect(store.rightPanelMode == nil)

        await store.clearWorkspace()

        #expect(store.workspaceRoot.isEmpty)
        #expect(!store.isGitRepository)
        #expect(store.currentBranch.isEmpty)
        #expect(store.availableBranches.isEmpty)
        #expect(store.rightPanelMode == nil)
    }

    @Test("Removing a workspace deletes sessions but preserves project files")
    func removingWorkspacePreservesProjectFiles() async throws {
        let suiteName = "WorkspaceRemovalTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        let markerURL = projectURL.appendingPathComponent("keep.txt")
        try "keep".write(to: markerURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let conversation = Conversation(
            id: "workspace-thread",
            title: "Workspace thread",
            workspace: projectURL.path
        )
        let repository = WorkspaceLifecycleRepository(
            snapshots: [
                ConversationSnapshot(
                    conversation: conversation,
                    modelBackend: ModelBackend.foundationApple.rawValue,
                    blocks: [ChatBlock(kind: .assistant, text: "Persisted")],
                    transcript: nil
                )
            ]
        )
        let store = ChatStore(
            conversationRepository: repository,
            gitService: WorkspaceLifecycleGitService(),
            workspaceDefaults: defaults
        )
        await store.restoreSessions()
        await store.restoreSession(id: conversation.id)

        await store.removeWorkspace(projectURL.path)

        #expect(store.threads.isEmpty)
        #expect(store.activeThreadId == nil)
        #expect(store.agentRuntimeProjectionStore.snapshot.activeThreadID == nil)
        #expect(store.workspaceRoot.isEmpty)
        #expect(await repository.load(id: conversation.id) == nil)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test("Workspace replacement keeps runtime admission closed until commit")
    func workspaceReplacementKeepsAdmissionClosed() async throws {
        let suiteName = "WorkspaceAdmissionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let path = "/tmp/workspace-admission"
        let conversation = Conversation(
            id: "admission-thread",
            title: "Admission",
            workspace: path
        )
        let gate = WorkspaceDeletionGate()
        let repository = WorkspaceLifecycleRepository(
            snapshots: [
                ConversationSnapshot(
                    conversation: conversation,
                    modelBackend: ModelBackend.foundationApple.rawValue,
                    blocks: [],
                    transcript: nil
                )
            ],
            deletionGate: gate
        )
        let store = ChatStore(
            conversationRepository: repository,
            gitService: WorkspaceLifecycleGitService(),
            workspaceDefaults: defaults
        )
        await store.restoreSessions()
        await store.restoreSession(id: conversation.id)

        let removal = Task { await store.removeWorkspace(path) }
        await gate.waitUntilEntered()
        let admittedDuringTransition = await store.agentRuntime.runOperation(
            turnID: TurnID(),
            operation: {}
        )

        #expect(!admittedDuringTransition)
        await gate.release()
        await removal.value

        let admittedAfterTransition = await store.agentRuntime.runOperation(
            turnID: TurnID(),
            operation: {}
        )
        #expect(admittedAfterTransition)
    }
}

private actor WorkspaceLifecycleRepository: ConversationRepository {
    private var snapshots: [String: ConversationSnapshot]
    private let deletionGate: WorkspaceDeletionGate?

    init(
        snapshots: [ConversationSnapshot] = [],
        deletionGate: WorkspaceDeletionGate? = nil
    ) {
        self.snapshots = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.conversation.id, $0) }
        )
        self.deletionGate = deletionGate
    }

    func save(_ snapshot: ConversationSnapshot) {
        snapshots[snapshot.conversation.id] = snapshot
    }

    func load(id: String) -> ConversationSnapshot? {
        snapshots[id]
    }

    func list() -> [ConversationSnapshot] {
        Array(snapshots.values)
    }

    func delete(id: String) async {
        if let deletionGate {
            await deletionGate.pause()
        }
        snapshots[id] = nil
    }
}

private actor WorkspaceDeletionGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
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
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor WorkspaceLifecycleGitService: GitRepositoryServicing {
    private let repository: Bool
    private let branch: String?
    private let branches: [String]

    init(
        isRepository: Bool = false,
        branch: String? = nil,
        branches: [String] = []
    ) {
        self.repository = isRepository
        self.branch = branch
        self.branches = branches
    }

    func isGitRepository(at directory: URL) -> Bool { repository }
    func currentBranch(at directory: URL) -> String? { branch }
    func allBranches(at directory: URL) -> [String] { branches }
    func undoCommit(expectedHash: String, at directory: URL) -> String? { nil }
    func checkout(branch: String, at directory: URL) -> Bool { false }
    func fetchChangedFiles(at url: URL) throws -> [GitFileStatus] { [] }
    func fetchDiff(for filePath: String, at url: URL) throws -> [DiffLine] { [] }
}
