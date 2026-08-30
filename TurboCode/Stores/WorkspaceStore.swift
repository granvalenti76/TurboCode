import Foundation
import Observation

/// Owns the selected workspace and its derived Git presentation state.
///
/// `WorkspaceLifecycleCoordinator` composes context changes with runtime and
/// persistence. This observable store owns only workspace and Git projections.
@MainActor
@Observable
final class WorkspaceStore {
    var root: String = ""
    var selectedProject: String?

    var diffSections: [FileDiffSection] = []
    var isLoadingDiffs = false
    var diffLoadError: String?

    var isGitRepository = false
    var currentBranch: String = ""
    var availableBranches: [String] = []

    var label: String {
        root.isEmpty ? "No workspace" : URL(fileURLWithPath: root).lastPathComponent
    }

    /// Recent paths remain observable in memory so sidebar removals render
    /// immediately, while every mutation is mirrored to UserDefaults for the
    /// next launch. Reading only from UserDefaults would bypass Observation.
    var recentWorkspaces: [String] {
        didSet {
            defaults.set(recentWorkspaces, forKey: Self.recentWorkspacesKey)
        }
    }

    private static let recentWorkspacesKey = "recentWorkspaces"

    private var diffLoadID: UUID?
    private let gitService: any GitRepositoryServicing
    private let reviewDraftStore: ReviewDraftStore
    private let defaults: UserDefaults

    init(
        gitService: any GitRepositoryServicing,
        reviewDraftStore: ReviewDraftStore = ReviewDraftStore(),
        defaults: UserDefaults = .standard
    ) {
        self.gitService = gitService
        self.reviewDraftStore = reviewDraftStore
        self.defaults = defaults
        self.recentWorkspaces = defaults.stringArray(
            forKey: Self.recentWorkspacesKey
        ) ?? []
    }

    /// Applies a user-selected workspace synchronously. Refreshes remain
    /// explicit so the lifecycle coordinator can rebuild its model session
    /// before async Git results become visible.
    func selectWorkspace(_ path: String) {
        root = path
        reviewDraftStore.begin(workspaceRoot: path)
        resetGitState()

        var recent = recentWorkspaces
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        recentWorkspaces = Array(recent.prefix(10))
        selectedProject = URL(fileURLWithPath: path).lastPathComponent

        // Changing roots invalidates the visible diff immediately. The load ID
        // check in reloadDiffs prevents an older async request from repopulating it.
        diffSections = []
    }

    /// Clears an explicit workspace selection while preserving the sidebar
    /// project filter, matching ChatStore's existing navigation behavior.
    func clearWorkspace() {
        root = ""
        reviewDraftStore.begin(workspaceRoot: "")
        diffLoadID = nil
        diffSections = []
        diffLoadError = nil
        isLoadingDiffs = false
        resetGitState()
    }

    /// Removes one recent workspace and clears derived state only when it is
    /// the active root. The return value lets the lifecycle coordinator rebuild
    /// runtime context only when the selected workspace actually changed.
    @discardableResult
    func removeWorkspace(_ path: String) -> Bool {
        recentWorkspaces = recentWorkspaces.filter { $0 != path }
        guard root == path else { return false }

        root = ""
        reviewDraftStore.begin(workspaceRoot: "")
        selectedProject = nil
        resetGitState()
        diffSections = []
        isLoadingDiffs = false
        return true
    }

    func reloadDiffs() async {
        guard !root.isEmpty else {
            diffLoadID = nil
            diffSections = []
            diffLoadError = nil
            isLoadingDiffs = false
            return
        }

        let requestedWorkspace = root
        let loadID = UUID()
        diffLoadID = loadID
        isLoadingDiffs = true
        diffLoadError = nil
        diffSections = []
        defer {
            if diffLoadID == loadID {
                isLoadingDiffs = false
            }
        }

        let url = URL(fileURLWithPath: requestedWorkspace)
        let sections = await FileDiffSection.fromGit(at: url, service: gitService)

        // Workspace changes and newer reloads make this result stale. Never
        // publish filesystem state captured for a no-longer-active root.
        guard !Task.isCancelled,
              root == requestedWorkspace,
              diffLoadID == loadID else { return }

        if let sections {
            diffSections = sections
            diffLoadError = nil
            reviewDraftStore.reconcile(
                workspaceRoot: requestedWorkspace,
                sections: sections
            )
        } else {
            diffSections = []
            diffLoadError = "Not a git repository or git unavailable"
        }
    }

    func refreshGitBranches() async {
        guard !root.isEmpty else {
            resetGitState()
            return
        }

        let requestedWorkspace = root
        let url = URL(fileURLWithPath: requestedWorkspace)
        let isRepository = await gitService.isGitRepository(at: url)
        guard root == requestedWorkspace, !Task.isCancelled else { return }
        guard isRepository else {
            resetGitState()
            return
        }

        let branch = await gitService.currentBranch(at: url)
        let branches = await gitService.allBranches(at: url)
        guard root == requestedWorkspace, !Task.isCancelled else { return }

        isGitRepository = true
        currentBranch = branch ?? ""
        availableBranches = branches
    }

    func refreshGitAfterToolMutation() async {
        await refreshGitBranches()
        await reloadDiffs()
    }

    /// Changes branches only through the injected service, then reloads the
    /// authoritative repository state instead of trusting the requested name.
    func switchToBranch(_ branch: String) async {
        guard !root.isEmpty else { return }
        let url = URL(fileURLWithPath: root)
        guard await gitService.checkout(branch: branch, at: url) else { return }
        currentBranch = branch
        await refreshGitBranches()
    }

    private func resetGitState() {
        isGitRepository = false
        currentBranch = ""
        availableBranches = []
    }
}
