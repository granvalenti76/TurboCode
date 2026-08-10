import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Workspace store")
struct WorkspaceStoreTests {
    @Test("Recent workspaces are unique, newest-first, and limited")
    func recentWorkspacesAreLimitedAndOrdered() throws {
        let suiteName = "WorkspaceStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WorkspaceStore(
            gitService: WorkspaceGitServiceStub(),
            defaults: defaults
        )

        for index in 0..<12 {
            store.selectWorkspace("/tmp/project-\(index)")
        }
        store.selectWorkspace("/tmp/project-5")

        #expect(store.recentWorkspaces.count == 10)
        #expect(store.recentWorkspaces.first == "/tmp/project-5")
        #expect(store.recentWorkspaces.filter { $0 == "/tmp/project-5" }.count == 1)
        #expect(store.selectedProject == "project-5")
    }

    @Test("Removing a recent workspace updates the sidebar and preserves its directory")
    func removingRecentWorkspaceIsObservableAndNonDestructive() async throws {
        let suiteName = "WorkspaceStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let store = WorkspaceStore(
            gitService: WorkspaceGitServiceStub(),
            defaults: defaults
        )
        store.selectWorkspace(projectURL.path)
        store.clearWorkspace()

        await confirmation("Recent workspace mutation is observed") { observed in
            withObservationTracking {
                _ = store.recentWorkspaces
            } onChange: {
                observed()
            }

            #expect(!store.removeWorkspace(projectURL.path))
        }

        #expect(store.recentWorkspaces.isEmpty)
        #expect(defaults.stringArray(forKey: "recentWorkspaces")?.isEmpty == true)
        #expect(FileManager.default.fileExists(atPath: projectURL.path))
    }

    @Test("Clearing a workspace resets derived Git and diff state")
    func clearWorkspaceResetsDerivedState() {
        let store = WorkspaceStore(gitService: WorkspaceGitServiceStub())
        store.root = "/tmp/project"
        store.selectedProject = "project"
        store.isGitRepository = true
        store.currentBranch = "feature/refactor"
        store.availableBranches = ["main", "feature/refactor"]
        store.diffLoadError = "old error"
        store.isLoadingDiffs = true

        store.clearWorkspace()

        #expect(store.root.isEmpty)
        #expect(!store.isGitRepository)
        #expect(store.currentBranch.isEmpty)
        #expect(store.availableBranches.isEmpty)
        #expect(store.diffSections.isEmpty)
        #expect(store.diffLoadError == nil)
        #expect(!store.isLoadingDiffs)
        // The project filter is independent sidebar navigation state.
        #expect(store.selectedProject == "project")
    }

    @Test("Branch refresh publishes the service snapshot")
    func branchRefreshPublishesServiceSnapshot() async {
        let gitService = WorkspaceGitServiceStub(
            isRepository: true,
            currentBranch: "feature/refactor",
            branches: ["main", "feature/refactor"]
        )
        let store = WorkspaceStore(gitService: gitService)
        store.root = "/tmp/project"

        await store.refreshGitBranches()

        #expect(store.isGitRepository)
        #expect(store.currentBranch == "feature/refactor")
        #expect(store.availableBranches == ["main", "feature/refactor"])
    }
}

private actor WorkspaceGitServiceStub: GitRepositoryServicing {
    private let isRepository: Bool
    private var branch: String?
    private let branches: [String]

    init(
        isRepository: Bool = false,
        currentBranch: String? = nil,
        branches: [String] = []
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
        self.branch = branch
        return true
    }

    func fetchChangedFiles(at url: URL) throws -> [GitFileStatus] {
        []
    }

    func fetchDiff(for filePath: String, at url: URL) throws -> [DiffLine] {
        []
    }
}
