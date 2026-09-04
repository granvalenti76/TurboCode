/// Coordinates workspace context with runtime, conversation persistence, and
/// derived Git presentation. The workspace store owns values; this type owns
/// the ordered cross-domain transitions that replace those values.
@MainActor
final class WorkspaceLifecycleCoordinator {
    private let workspace: WorkspaceStore
    private let conversations: ConversationStore
    private let timeline: ChatTimelineStore
    private let activity: AgentActivityStore
    private let workbench: WorkbenchStore
    private let presentation: ChatPresentationViewModel
    private let runtime: AgentRuntime
    private let profiles: ProfileSelectionCoordinator
    private let sessions: ConversationSessionCoordinator
    private let transitionBarrier: RuntimeTransitionBarrier

    init(
        workspace: WorkspaceStore,
        conversations: ConversationStore,
        timeline: ChatTimelineStore,
        activity: AgentActivityStore,
        workbench: WorkbenchStore,
        presentation: ChatPresentationViewModel,
        runtime: AgentRuntime,
        profiles: ProfileSelectionCoordinator,
        sessions: ConversationSessionCoordinator,
        transitionBarrier: RuntimeTransitionBarrier
    ) {
        self.workspace = workspace
        self.conversations = conversations
        self.timeline = timeline
        self.activity = activity
        self.workbench = workbench
        self.presentation = presentation
        self.runtime = runtime
        self.profiles = profiles
        self.sessions = sessions
        self.transitionBarrier = transitionBarrier
    }

    /// Installs one workspace capability context, then publishes Git-derived
    /// state only for that same root. The two independent reads run in parallel
    /// and are joined so no coordinator-owned refresh outlives the transition.
    func selectWorkspace(_ path: String) async {
        await transitionBarrier.performContextChange {
            workspace.selectWorkspace(path)
            _ = profiles.refreshSkills()
            await profiles.rebuildSession(discardingCapabilityContext: true)
            workbench.rightPanelMode = nil
            workbench.dismissTranscript()
        }

        async let diffs: Void = workspace.reloadDiffs()
        async let branches: Void = workspace.refreshGitBranches()
        _ = await (diffs, branches)
    }

    /// Clears workspace-specific tools and provider instructions together with
    /// derived Git state. Refreshing the skill catalog before the rebuild keeps
    /// capabilities from the previous root out of later rootless messages.
    func clearWorkspace() async {
        await transitionBarrier.performContextChange {
            workspace.clearWorkspace()
            _ = profiles.refreshSkills()
            await profiles.rebuildSession(discardingCapabilityContext: true)
            workbench.rightPanelMode = nil
            workbench.dismissTranscript()
        }
    }

    /// Removes only TurboCode metadata and persisted chats for a workspace;
    /// project files are never touched. Repository-confirmed deletion IDs are
    /// the sole authority for removing visible conversations.
    func removeWorkspace(_ path: String) async {
        await transitionBarrier.performContextChange {
            let activeThreadBeforeRemoval = conversations.activeThreadID
            let persistenceRemoval = await sessions.removeWorkspace(path)
            let removedActiveThread = activeThreadBeforeRemoval.map(
                persistenceRemoval.deletedConversationIDs.contains
            ) ?? false
            let removedActiveWorkspace = workspace.removeWorkspace(path)

            if removedActiveThread {
                _ = await runtime.apply(.switchThread(threadID: nil))
                timeline.reset()
                resetActivityPresentation()
                workbench.dismissTranscript()
            }

            if removedActiveWorkspace {
                workbench.rightPanelMode = nil
                _ = profiles.refreshSkills()
                await profiles.rebuildSession(keepingHistory: false)
            }

            if persistenceRemoval.deletionErrors.isEmpty {
                presentation.errorMessage = nil
            } else {
                let details = persistenceRemoval.deletionErrors.joined(separator: "; ")
                presentation.errorMessage = "Some workspace chats could not be removed: "
                    + details
            }
        }
    }

    private func resetActivityPresentation() {
        activity.reset()
        if workbench.rightPanelMode == .activity {
            workbench.rightPanelMode = nil
        }
    }
}
