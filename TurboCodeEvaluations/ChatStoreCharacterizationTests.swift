import Foundation
import Observation
import Testing
@testable import TurboCode

@MainActor
@Suite("ChatStore characterization")
struct ChatStoreCharacterizationTests {
    @Test("Approval requests are presented once in FIFO order")
    func approvalQueueIsFIFOAndDeduplicated() {
        let store = ChatStore(
            conversationRepository: CharacterizationConversationRepository()
        )
        let first = ApprovalRequest(
            id: "first",
            operation: "write",
            path: "/tmp/first.txt",
            summary: "Write first.txt"
        )
        let second = ApprovalRequest(
            id: "second",
            operation: "delete",
            path: "/tmp/second.txt",
            summary: "Delete second.txt"
        )

        store.presentApproval(first)
        store.presentApproval(second)
        store.presentApproval(second)

        #expect(store.pendingApproval?.id == first.id)

        store.dismissApproval(id: first.id)
        #expect(store.pendingApproval?.id == second.id)

        store.dismissApproval(id: second.id)
        #expect(store.pendingApproval == nil)
    }

    @Test("Compatibility approval envelopes retain typed review data")
    func approvalEnvelopeDecodesReviewData() throws {
        let request = try #require(ApprovalRequest(toolOutput: """
        TURBOCODE_APPROVAL_REQUIRED
        approval_id: approval-1
        operation: move
        path: /tmp/source.txt
        destination: /tmp/destination.txt
        summary: Move source.txt
        """))

        #expect(request.id == "approval-1")
        #expect(request.operation == "move")
        #expect(request.path == "/tmp/source.txt")
        #expect(request.destination == "/tmp/destination.txt")
        #expect(request.summary == "Move source.txt")
    }

    @Test("Incomplete approval envelopes are rejected")
    func incompleteApprovalEnvelopeIsRejected() {
        let request = ApprovalRequest(toolOutput: """
        TURBOCODE_APPROVAL_REQUIRED
        approval_id: approval-1
        operation: delete
        path: /tmp/file.txt
        """)

        #expect(request == nil)
    }

    @Test("Git refresh publishes repository and branch state")
    func gitRefreshPublishesServiceSnapshot() async {
        let gitService = CharacterizationGitService(
            isRepository: true,
            currentBranch: "feature/refactor",
            branches: ["main", "feature/refactor"]
        )
        let store = ChatStore(
            conversationRepository: CharacterizationConversationRepository(),
            gitService: gitService
        )
        store.workspaceRoot = "/tmp/project"

        await store.refreshGitBranches()

        #expect(store.isGitRepository)
        #expect(store.currentBranch == "feature/refactor")
        #expect(store.availableBranches == ["main", "feature/refactor"])
    }

    @Test("Successful checkout refreshes branch state")
    func checkoutRefreshesBranchState() async {
        let gitService = CharacterizationGitService(
            isRepository: true,
            currentBranch: "main",
            branches: ["main", "feature/refactor"]
        )
        let store = ChatStore(
            conversationRepository: CharacterizationConversationRepository(),
            gitService: gitService
        )
        store.workspaceRoot = "/tmp/project"

        await store.switchToBranch("feature/refactor")

        #expect(await gitService.checkedOutBranches() == ["feature/refactor"])
        #expect(store.currentBranch == "feature/refactor")
        #expect(store.availableBranches == ["main", "feature/refactor"])
    }

    @Test("Forwarded workspace state remains observable")
    func forwardedWorkspaceStateRemainsObservable() async {
        let gitService = CharacterizationGitService(
            isRepository: true,
            currentBranch: "feature/refactor",
            branches: ["main", "feature/refactor"]
        )
        let store = ChatStore(
            conversationRepository: CharacterizationConversationRepository(),
            gitService: gitService
        )
        store.workspaceRoot = "/tmp/project"

        await confirmation("Nested workspace mutation is observed") { observed in
            withObservationTracking {
                _ = store.currentBranch
            } onChange: {
                observed()
            }
            await store.refreshGitBranches()
        }

        #expect(store.currentBranch == "feature/refactor")
    }
}

private struct CharacterizationConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}

private actor CharacterizationGitService: GitRepositoryServicing {
    private let isRepository: Bool
    private var branch: String?
    private let branches: [String]
    private var checkouts: [String] = []

    init(
        isRepository: Bool,
        currentBranch: String?,
        branches: [String]
    ) {
        self.isRepository = isRepository
        self.branch = currentBranch
        self.branches = branches
    }

    func isGitRepository(at directory: URL) -> Bool {
        isRepository
    }

    func currentBranch(at directory: URL) -> String? {
        branch
    }

    func allBranches(at directory: URL) -> [String] {
        branches
    }

    func undoCommit(expectedHash: String, at directory: URL) -> String? {
        nil
    }

    func checkout(branch: String, at directory: URL) -> Bool {
        checkouts.append(branch)
        self.branch = branch
        return true
    }

    func fetchChangedFiles(at url: URL) throws -> [GitFileStatus] {
        []
    }

    func fetchDiff(for filePath: String, at url: URL) throws -> [DiffLine] {
        []
    }

    func checkedOutBranches() -> [String] {
        checkouts
    }
}
