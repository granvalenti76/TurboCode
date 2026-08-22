/// Coordinates in-memory conversation boundaries that must update runtime and
/// presentation together. Durable storage remains in the session coordinator;
/// model routing remains in the profile coordinator.
@MainActor
final class ConversationLifecycleCoordinator {
    private let conversations: ConversationStore
    private let timeline: ChatTimelineStore
    private let activity: AgentActivityStore
    private let workbench: WorkbenchStore
    private let workspace: WorkspaceStore
    private let composer: ComposerViewModel
    private let reviewDrafts: ReviewDraftStore
    private let runtime: AgentRuntime
    private let profiles: ProfileSelectionCoordinator

    init(
        conversations: ConversationStore,
        timeline: ChatTimelineStore,
        activity: AgentActivityStore,
        workbench: WorkbenchStore,
        workspace: WorkspaceStore,
        composer: ComposerViewModel,
        reviewDrafts: ReviewDraftStore,
        runtime: AgentRuntime,
        profiles: ProfileSelectionCoordinator
    ) {
        self.conversations = conversations
        self.timeline = timeline
        self.activity = activity
        self.workbench = workbench
        self.workspace = workspace
        self.composer = composer
        self.reviewDrafts = reviewDrafts
        self.runtime = runtime
        self.profiles = profiles
    }

    /// Selects thread identity only after every provider and profile operation
    /// has settled. Presentation owned by the previous conversation is cleared
    /// before the runtime can publish events under the new identity.
    func selectThread(_ id: String) async {
        await finishActiveResponseBeforeTransition()
        if id != conversations.activeThreadID {
            workbench.dismissWorkspaceListingInspector()
            workbench.dismissDiffPatchReview()
            reviewDrafts.discardAll()
        }
        conversations.activeThreadID = id
        _ = await runtime.apply(.switchThread(threadID: id))
    }

    /// Creates one empty conversation boundary and installs its runtime
    /// identity before rebuilding the provider session. Keeping this sequence
    /// in one coordinator prevents views from observing a mixed old/new chat.
    func createThread(
        title: String = "New Chat",
        mode: ConversationMode = .agent
    ) async {
        await finishActiveResponseBeforeTransition()
        workbench.dismissWorkspaceListingInspector()
        workbench.dismissDiffPatchReview()
        reviewDrafts.discardAll()
        let thread = conversations.createThread(
            title: title,
            workspace: workspace.root.isEmpty ? nil : workspace.root,
            mode: mode
        )
        _ = await runtime.apply(.switchThread(threadID: thread.id))
        timeline.reset()
        resetActivityPresentation()
        await profiles.rebuildSession(keepingHistory: false)
    }

    /// Makes message and application-command entry points safe without losing
    /// visible blocks created by an older orphaned flow. A newly empty thread
    /// receives one matching runtime identity and model session before use.
    func ensureActiveThread() async {
        let hasOrphanedBlocks = !timeline.blocks.isEmpty
        let created = conversations.ensureActiveThread(
            workspace: workspace.root.isEmpty ? nil : workspace.root,
            mode: composer.mode
        )
        guard created else { return }

        if let threadID = conversations.activeThreadID {
            _ = await runtime.apply(.switchThread(threadID: threadID))
        }
        guard !hasOrphanedBlocks else { return }
        timeline.reset()
        resetActivityPresentation()
        await profiles.rebuildSession(keepingHistory: false)
    }

    /// Navigation is a transaction boundary: release the old operation before
    /// changing identity so its final persistence pass cannot target the new
    /// conversation.
    private func finishActiveResponseBeforeTransition() async {
        await runtime.beginQuiescence()
        await profiles.cancelAndWaitForTransitions()
        await runtime.cancelAndWaitForOperation()
        await runtime.endQuiescence()
    }

    private func resetActivityPresentation() {
        activity.reset()
        if workbench.rightPanelMode == .activity {
            workbench.rightPanelMode = nil
        }
    }
}
