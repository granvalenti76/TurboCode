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
    private let runtime: AgentRuntime
    private let profiles: ProfileSelectionCoordinator

    init(
        conversations: ConversationStore,
        timeline: ChatTimelineStore,
        activity: AgentActivityStore,
        workbench: WorkbenchStore,
        workspace: WorkspaceStore,
        composer: ComposerViewModel,
        runtime: AgentRuntime,
        profiles: ProfileSelectionCoordinator
    ) {
        self.conversations = conversations
        self.timeline = timeline
        self.activity = activity
        self.workbench = workbench
        self.workspace = workspace
        self.composer = composer
        self.runtime = runtime
        self.profiles = profiles
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
        activity.reset()
        if workbench.rightPanelMode == .activity {
            workbench.rightPanelMode = nil
        }
        await profiles.rebuildSession(keepingHistory: false)
    }
}
