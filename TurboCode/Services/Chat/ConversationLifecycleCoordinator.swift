import Foundation

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
    private let presentation: ChatPresentationViewModel
    private let runtime: AgentRuntime
    private let profiles: ProfileSelectionCoordinator
    private let sessions: ConversationSessionCoordinator
    private let transitionBarrier: RuntimeTransitionBarrier
    private let statistics: ComposerSessionStatisticsStore
    /// Counts navigation requests in arrival order. Context changes queue
    /// behind the transition barrier, so several clicks can be waiting at
    /// once; a queued opening that is no longer the latest request is skipped
    /// instead of restoring a conversation the user has already left.
    private var navigationRequest: UInt64 = 0

    init(
        conversations: ConversationStore,
        timeline: ChatTimelineStore,
        activity: AgentActivityStore,
        workbench: WorkbenchStore,
        workspace: WorkspaceStore,
        composer: ComposerViewModel,
        reviewDrafts: ReviewDraftStore,
        presentation: ChatPresentationViewModel,
        runtime: AgentRuntime,
        profiles: ProfileSelectionCoordinator,
        sessions: ConversationSessionCoordinator,
        transitionBarrier: RuntimeTransitionBarrier,
        statistics: ComposerSessionStatisticsStore
    ) {
        self.conversations = conversations
        self.timeline = timeline
        self.activity = activity
        self.workbench = workbench
        self.workspace = workspace
        self.composer = composer
        self.reviewDrafts = reviewDrafts
        self.presentation = presentation
        self.runtime = runtime
        self.profiles = profiles
        self.sessions = sessions
        self.transitionBarrier = transitionBarrier
        self.statistics = statistics
    }

    /// Selects thread identity only after every provider and profile operation
    /// has settled. Presentation owned by the previous conversation is cleared
    /// before the runtime can publish events under the new identity.
    func selectThread(_ id: String) async {
        let request = beginNavigationRequest()
        await transitionBarrier.performContextChange {
            guard request == navigationRequest else { return }
            await selectSettledThread(id)
        }
    }

    private func selectSettledThread(_ id: String) async {
        if id != conversations.activeThreadID {
            workbench.dismissWorkspaceListingInspector()
            workbench.dismissDiffPatchReview()
            workbench.dismissTranscript()
            reviewDrafts.discardAll()
        }
        conversations.activeThreadID = id
        statistics.activate(conversationID: id)
        _ = await runtime.apply(.switchThread(threadID: id))
    }

    /// Opens one conversation and publishes the final chat route only after
    /// its matching runtime/timeline context is installed.
    func openThread(_ id: String) async {
        let request = beginNavigationRequest()
        await transitionBarrier.performContextChange {
            guard request == navigationRequest else { return }
            // Decide inside the barrier. While this opening was queued, an
            // earlier one may have installed another conversation; the state
            // seen at click time would then select this thread's ID on top of
            // that conversation's timeline.
            if timeline.blocks.isEmpty || conversations.activeThreadID != id {
                await restoreSettledSession(id: id)
            } else {
                await selectSettledThread(id)
            }
        }
        workbench.setRoute(.chat)
    }

    /// Registers one navigation intent. Creation and deletion register too, so
    /// they supersede queued openings, but they are never skipped themselves:
    /// both carry an effect the user asked for beyond showing a conversation.
    private func beginNavigationRequest() -> UInt64 {
        navigationRequest &+= 1
        return navigationRequest
    }

    /// Creates one empty conversation boundary and installs its runtime
    /// identity before rebuilding the provider session. Keeping this sequence
    /// in one coordinator prevents views from observing a mixed old/new chat.
    func createThread(
        title: String = "New Chat",
        mode: ConversationMode = .agent
    ) async {
        _ = beginNavigationRequest()
        await transitionBarrier.performContextChange {
            workbench.dismissWorkspaceListingInspector()
            workbench.dismissDiffPatchReview()
            workbench.dismissTranscript()
            reviewDrafts.discardAll()
            let thread = conversations.createThread(
                title: title,
                workspace: workspace.root.isEmpty ? nil : workspace.root,
                mode: mode
            )
            _ = await runtime.apply(.switchThread(threadID: thread.id))
            statistics.activate(conversationID: thread.id)
            timeline.reset()
            resetActivityPresentation()
            await profiles.rebuildSession(keepingHistory: false)
        }
    }

    /// Restores one durable conversation as an ordered runtime transition.
    /// Immutable disk state is installed before model history is rebuilt, so
    /// presentation, provider selection, and transcript share one thread ID.
    func restoreSession(id: String) async {
        let request = beginNavigationRequest()
        await transitionBarrier.performContextChange {
            guard request == navigationRequest else { return }
            await restoreSettledSession(id: id)
        }
    }

    /// Result consumed by deletion, which may only fall back to an empty
    /// draft when the successor genuinely has no durable file yet.
    private enum RestoreOutcome {
        case restored
        case missing
        case unreadable
    }

    @discardableResult
    private func restoreSettledSession(id: String) async -> RestoreOutcome {
        let startedAt = Date()
        let snapshot: ConversationSnapshot
        switch await sessions.load(id: id) {
        case .loaded(let loaded):
            snapshot = loaded
        case .missing:
            return .missing
        case .unreadable(let reason):
            // The current context stays installed; activating this thread with
            // an empty timeline would let the next checkpoint overwrite it.
            let title = conversations.conversation(id: id)?.title ?? "the conversation"
            presentation.errorMessage = "Could not open “\(title)”: \(reason) "
                + "The saved file was left untouched."
            return .unreadable
        }
        guard conversations.threads.contains(where: { $0.id == id }) else {
            return .missing
        }

        workbench.dismissWorkspaceListingInspector()
        workbench.dismissDiffPatchReview()
        workbench.dismissTranscript()
        reviewDrafts.discardAll()
        conversations.activeThreadID = id
        statistics.activate(
            conversationID: id,
            restored: snapshot.statistics
        )
        _ = await runtime.apply(.restore(threadID: id))
        timeline.restore(snapshot.blocks)
        resetActivityPresentation()
        if let restoredWorkspace = snapshot.conversation.workspace,
           workspace.root != restoredWorkspace {
            // Adopt persisted context directly. Running the interactive
            // workspace transition here would rebuild the provider twice.
            workspace.root = restoredWorkspace
        }

        await profiles.refreshSkillsIfNeeded()
        await profiles.restoreModelSelection(snapshot.modelBackend)
        let restoredHistory = snapshot.transcript.map {
            SessionRebuildHistory.prepare(
                $0,
                keepingHistory: true,
                discardingCapabilityContext: false
            )
        } ?? SessionRebuildHistory.fromVisibleBlocks(snapshot.blocks)
        await profiles.rebuildSession(
            keepingHistory: false,
            restoringHistory: restoredHistory,
            restoringProjection: snapshot.contextProjection,
            invalidatingComposerContext: false
        )
        await runtime.restoreSteering(snapshot.steering)
        await AgentDiagnosticsRecorder.shared.recordBoundary(
            RuntimeBoundaryMetric(
                boundary: .restore,
                backend: snapshot.modelBackend,
                durationMilliseconds: max(
                    0,
                    Int(Date().timeIntervalSince(startedAt) * 1_000)
                )
            )
        )
        return .restored
    }

    /// Deletes durable state before changing the observable catalog. Removing
    /// the active conversation also clears its runtime identity and either
    /// restores the next snapshot or installs a valid unsaved draft.
    func deleteThread(id: String) async {
        let deletesActiveThread = conversations.activeThreadID == id
        if deletesActiveThread {
            // The old operation may still perform its final persistence pass;
            // release it before deleting the file that pass belongs to.
            _ = beginNavigationRequest()
            await transitionBarrier.performContextChange {
                await deleteSettledThread(id: id, deletesActiveThread: true)
            }
        } else {
            await deleteSettledThread(id: id, deletesActiveThread: false)
        }
    }

    private func deleteSettledThread(
        id: String,
        deletesActiveThread: Bool
    ) async {
        let nextThreadID: String?
        do {
            nextThreadID = try await sessions.delete(id: id)
        } catch {
            // Durable deletion is authoritative. Keeping the row visible avoids
            // a false success that would reverse itself on the next launch.
            presentation.errorMessage = "Could not delete the conversation: "
                + error.localizedDescription
            return
        }
        presentation.errorMessage = nil
        statistics.remove(conversationID: id)
        guard deletesActiveThread else { return }

        conversations.activeThreadID = nil
        _ = await runtime.apply(.switchThread(threadID: nil))
        timeline.reset()
        resetActivityPresentation()
        workbench.dismissTranscript()
        reviewDrafts.discardAll()

        if let nextThreadID {
            switch await restoreSettledSession(id: nextThreadID) {
            case .restored:
                break
            case .missing:
                // A new draft may not have reached disk yet. It remains a valid
                // catalog selection but starts with a fresh provider context.
                conversations.activeThreadID = nextThreadID
                _ = await runtime.apply(.switchThread(threadID: nextThreadID))
                await profiles.rebuildSession(keepingHistory: false)
            case .unreadable:
                // Never adopt an unreadable successor as an empty draft: it
                // would be saved over its own file. Leave no thread selected.
                await profiles.rebuildSession(keepingHistory: false)
            }
        } else {
            await profiles.rebuildSession(keepingHistory: false)
        }
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
            statistics.activate(conversationID: threadID)
            _ = await runtime.apply(.switchThread(threadID: threadID))
        }
        guard !hasOrphanedBlocks else { return }
        timeline.reset()
        resetActivityPresentation()
        await profiles.rebuildSession(keepingHistory: false)
    }

    private func resetActivityPresentation() {
        activity.reset()
        if workbench.rightPanelMode == .activity {
            workbench.rightPanelMode = nil
        }
    }
}
