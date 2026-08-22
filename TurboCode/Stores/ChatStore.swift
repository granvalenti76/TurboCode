import Foundation
import AppKit
import Observation

/// Temporary, non-invasive status shown after a local context compaction.
public struct LocalCompactionNotice: Equatable, Sendable {
    public let sourceCharacters: Int
    public let retainedCharacters: Int

    public init(sourceCharacters: Int, retainedCharacters: Int) {
        self.sourceCharacters = sourceCharacters
        self.retainedCharacters = retainedCharacters
    }
}

/// Application-level façade that composes the independent chat domains.
///
/// State and provider behavior belong to the injected stores/coordinators.
/// This type retains cross-domain use cases and the stable API consumed by
/// existing views while those views migrate to narrower dependencies.
@MainActor
@Observable
public final class ChatStore {
    /// Shared instance used by App Intents (runs in-process on macOS).
    public static var shared: ChatStore!

    // MARK: - Properties
    /// UI projection of runtime-owned work. Response and `/task` operations
    /// arrive as immutable snapshots; the UI never observes the runtime task.
    /// Codex handoff remains a separate transition until that profile boundary
    /// is extracted in a later slice.
    public var busy: Bool {
        agentRuntimeProjectionStore.hasActiveOperation
            || presentationViewModel.isProfileTransitioning
    }
#if DEBUG
    public var benchmarkRunning: Bool = false
    public var benchmarkStatus: String?
#endif

    /// Compatibility-internal error channel while send and transition use
    /// cases still migrate out of this facade. Views observe the narrower
    /// presentation model directly.
    private var error: String? {
        get { presentationViewModel.errorMessage }
        set { presentationViewModel.errorMessage = newValue }
    }

    // Orchestrator mode
    public var orchestratorMode: OrchestratorMode {
        modelRuntimeStore.orchestratorMode
    }

    /// Changes the routing mode as one awaited runtime transition. Swift
    /// property setters cannot suspend, so keeping mutation in a method avoids
    /// an untracked Task racing the next profile or send action.
    public func setOrchestratorMode(_ mode: OrchestratorMode) async {
        await profileSelectionCoordinator.setOrchestratorMode(mode)
    }

    // Internal only so the compatibility façade can forward legacy view API.
    let workspaceStore: WorkspaceStore
    let conversationStore: ConversationStore
    let toolInteractionStore: ToolInteractionStore
    let agentActivityStore: AgentActivityStore
    let agentRuntimeProjectionStore: AgentRuntimeProjectionStore
    let composerViewModel: ComposerViewModel
    let presentationViewModel: ChatPresentationViewModel
    let timelineStore: ChatTimelineStore
    let workbenchStore: WorkbenchStore
    let reviewDraftStore: ReviewDraftStore
    let codexRuntimeStore: CodexRuntimeStore
    let modelRuntimeStore: ModelRuntimeStore
    let agentRuntime: AgentRuntime
    let responseCoordinator: ChatResponseCoordinator
    private let sessionCoordinator: ConversationSessionCoordinator
    private let profileSelectionCoordinator: ProfileSelectionCoordinator
    private let independentTaskCoordinator: IndependentTaskCoordinator
    private let reviewCoordinator: ReviewCoordinator
    // MARK: - Onboarding

    /// Ensures the current `~/.turbocode/` layout exists and applies additive migrations.
    public func ensureOnboarding() async {
        do {
            try TurboCodeConfig.shared.performOnboarding()
            modelRuntimeStore.applyOnboarding(
                tuning: try TurboCodeConfig.shared.loadAgentTuning(),
                workspaceRoot: workspaceRoot
            )
            await reloadRemoteModels()
        } catch {
            print("[TurboCode] Onboarding failed: \(error.localizedDescription)")
        }
        do {
            try ProductDocumentationStore.live.installBundledDocumentation()
        } catch {
            print("[TurboCode] Documentation installation failed: \(error.localizedDescription)")
        }
    }
    public convenience init() {
        self.init(conversationRepository: DiskConversationRepository())
    }

    init(
        conversationRepository: any ConversationRepository,
        gitService: any GitRepositoryServicing = GitDiffService(),
        diffPatchService: any DiffPatchApplying = DiffPatchService()
    ) {
        let toolInteractions = ToolInteractionStore()
        let agentActivity = AgentActivityStore()
        let timeline = ChatTimelineStore()
        let codexRuntime = CodexRuntimeStore()
        let nativeRunner = NativeResponseRunner()
        let reviewDraft = ReviewDraftStore()
        let modelRuntime = ModelRuntimeStore()
        let runtimeProjection = AgentRuntimeProjectionStore()
        let composer = ComposerViewModel()
        let presentation = ChatPresentationViewModel()
        let agentRuntime = AgentRuntime { snapshot in
            await runtimeProjection.apply(snapshot)
            await timeline.applyRuntimeSnapshot(snapshot)
        }
        timeline.applyRuntimeSnapshot(runtimeProjection.snapshot)
        let llmSessionFactory = LiveLLMBackendSessionFactory(
            nativeRunner: nativeRunner,
            foundationModelsRuntime: modelRuntime.foundationModelsRuntime,
            codexRuntime: codexRuntime
        )
        let llmRuntime = LLMRuntime(sessionFactory: llmSessionFactory)
        let workspace = WorkspaceStore(
            gitService: gitService,
            reviewDraftStore: reviewDraft
        )
        let workbench = WorkbenchStore()
        let conversations = ConversationStore()
        let conversationPersistence = ConversationPersistenceService(
            repository: conversationRepository
        )
        self.conversationStore = conversations
        let sessionCoordinator = ConversationSessionCoordinator(
            conversations: conversations,
            timeline: timeline,
            modelRuntime: modelRuntime,
            persistence: conversationPersistence
        )
        self.sessionCoordinator = sessionCoordinator
        self.workspaceStore = workspace
        self.toolInteractionStore = toolInteractions
        self.agentActivityStore = agentActivity
        self.agentRuntimeProjectionStore = runtimeProjection
        self.composerViewModel = composer
        self.presentationViewModel = presentation
        self.timelineStore = timeline
        self.workbenchStore = workbench
        self.reviewDraftStore = reviewDraft
        self.codexRuntimeStore = codexRuntime
        self.modelRuntimeStore = modelRuntime
        self.agentRuntime = agentRuntime
        let responseCoordinator = ChatResponseCoordinator(
            timeline: timeline,
            toolInteractions: toolInteractions,
            agentActivity: agentActivity,
            agentRuntime: agentRuntime,
            llmRuntime: llmRuntime,
            workspaceNameProvider: {
                workspace.label.isEmpty ? nil : workspace.label
            },
            activityPresentationRequested: {
                workbench.rightPanelMode = .activity
            }
        )
        self.responseCoordinator = responseCoordinator
        let profileSelectionCoordinator = ProfileSelectionCoordinator(
            modelRuntime: modelRuntime,
            codexRuntime: codexRuntime,
            conversations: conversations,
            timeline: timeline,
            workspace: workspace,
            presentation: presentation,
            agentRuntime: agentRuntime,
            runtimeProjection: runtimeProjection,
            responseCoordinator: responseCoordinator
        )
        self.profileSelectionCoordinator = profileSelectionCoordinator
        self.independentTaskCoordinator = IndependentTaskCoordinator(
            runtime: agentRuntime,
            runtimeProjection: runtimeProjection,
            responseCoordinator: responseCoordinator,
            modelRuntime: modelRuntime,
            conversations: conversations,
            timeline: timeline,
            codexRuntime: codexRuntime,
            workspace: workspace,
            presentation: presentation,
            sessions: sessionCoordinator,
            profiles: profileSelectionCoordinator
        )
        self.reviewCoordinator = ReviewCoordinator(
            timeline: timeline,
            workbench: workbench,
            workspace: workspace,
            gitService: gitService,
            diffPatchService: diffPatchService
        )
    }

    /// Switch inference backend and rebuild the session, preserving user and
    /// assistant turns while removing model-specific transport entries.
    /// In the experimental compatibility mode the backend is always Apple
    /// on-device, so direct backend switching has no effect.
    public func switchBackend(to backend: ModelBackend) async {
        await profileSelectionCoordinator.switchBackend(to: backend)
    }

    public func switchRemoteModel(to id: String) async {
        await profileSelectionCoordinator.switchRemoteModel(to: id)
    }

    /// Selects Codex immediately, then verifies ChatGPT authentication and
    /// Luna availability in the background. Connection failure is a runtime
    /// state, not a reason to silently revert the user's menu selection.
    func selectCodexProfile(
        modelID: String? = nil,
        dynamicProfileID: UUID? = nil
    ) async {
        await profileSelectionCoordinator.selectCodexProfile(
            modelID: modelID,
            dynamicProfileID: dynamicProfileID
        )
    }

    /// Starts a cancellable Codex selection for UI callers. A later model
    /// choice supersedes the previous request instead of allowing an older
    /// App Server lookup to win after its await completes.
    @discardableResult
    func scheduleCodexProfileSelection(
        modelID: String? = nil,
        dynamicProfileID: UUID? = nil
    ) -> Task<Void, Never> {
        profileSelectionCoordinator.scheduleCodexProfileSelection(
            modelID: modelID,
            dynamicProfileID: dynamicProfileID
        )
    }

    /// Compatibility entry point for callers that only need to request a
    /// selection and do not need to await its completion.
    func requestCodexProfileSelection(
        modelID: String? = nil,
        dynamicProfileID: UUID? = nil
    ) {
        scheduleCodexProfileSelection(
            modelID: modelID,
            dynamicProfileID: dynamicProfileID
        )
    }

    /// Rechecks the App Server and Luna catalog without changing the selected
    /// profile. This is used by the visible Retry action after runtime errors.
    func retryCodexConnection() {
        profileSelectionCoordinator.retryCodexConnection()
    }

    /// Starts ChatGPT OAuth through App Server, opens the system default
    /// browser, and automatically finishes setup when the callback arrives.
    func signInToCodex() {
        profileSelectionCoordinator.signInToCodex()
    }

    func reopenCodexLoginPage() {
        profileSelectionCoordinator.reopenCodexLoginPage()
    }

    func selectBuiltInProfile(_ id: ProfileBaseModelID) async {
        await profileSelectionCoordinator.selectBuiltInProfile(id)
    }

    func selectDynamicProfile(_ id: UUID) async {
        await profileSelectionCoordinator.selectDynamicProfile(id)
    }

    /// Selects a profile with `delegate_task` as one atomic runtime change.
    ///
    /// The historical global "orchestrator" mode is the on-device compatibility
    /// path; production coordinator profiles run in standalone transport mode.
    /// Centralizing this transition keeps that implementation detail out of UI.
    func selectCoordinatorProfile(_ id: UUID) async {
        await profileSelectionCoordinator.selectCoordinatorProfile(id)
    }

    /// Leaves a custom profile and returns to the current built-in model.
    func selectDirectExecution() async {
        await profileSelectionCoordinator.selectDirectExecution()
    }

    func reloadDynamicProfiles(selecting id: UUID? = nil) async {
        await profileSelectionCoordinator.reloadDynamicProfiles(selecting: id)
    }

    public func reloadRemoteModels() async {
        await profileSelectionCoordinator.reloadRemoteModels()
    }

    public func isConfigured(_ model: RemoteModelConfig) -> Bool {
        modelRuntimeStore.isConfigured(model)
    }

    func setReasoningEffort(_ effort: ReasoningEffort) async {
        await profileSelectionCoordinator.setReasoningEffort(effort)
    }

    func setCodexReasoningEffort(_ effort: CodexReasoningEffort) {
        codexRuntimeStore.setReasoningEffort(effort)
    }

    /// Rebuild the session preserving conversation history. Capability changes
    /// keep visible turns but discard stale tool, reasoning, and skill state.
    /// Pass `keepingHistory: false` to start a fresh session (new thread).
    private func rebuildSession(
        keepingHistory: Bool = true,
        discardingCapabilityContext: Bool = false,
        restoringHistory: [ModelRuntimeStore.RestoredTranscriptEntry]? = nil
    ) async {
        await profileSelectionCoordinator.rebuildSession(
            keepingHistory: keepingHistory,
            discardingCapabilityContext: discardingCapabilityContext,
            restoringHistory: restoringHistory
        )
    }

    // MARK: - Actions

    /// Applies a provider-neutral activity event on the UI actor.
    ///
    /// A new delegation opens the native inspector once. Later phase changes
    /// never reopen a panel the user deliberately closed.
    func handleAgentActivityEvent(_ event: AgentActivityRuntimeEvent) {
        responseCoordinator.agentActivityChanged(event)
        if case .started = event {
            workbenchStore.rightPanelMode = .activity
        }
    }

    public func selectThread(_ id: String) async {
        await finishActiveResponseBeforeTransition()
        if id != activeThreadId {
            dismissWorkspaceListingInspector()
            workbenchStore.dismissDiffPatchReview()
            // Inline review drafts belong to the conversation where the user
            // authored them; never carry hidden instructions into another chat.
            reviewDraftStore.discardAll()
        }
        conversationStore.activeThreadID = id
        await projectRuntimeCommand(.switchThread(threadID: id))
    }

    /// Opens a conversation as one navigation transition. Restoring first keeps
    /// SwiftUI from building the previous, potentially large timeline merely to
    /// replace it one run-loop later when leaving a utility destination.
    public func openThread(_ id: String) async {
        await finishActiveResponseBeforeTransition()
        if blocks.isEmpty || activeThreadId != id {
            await restoreSession(id: id)
        } else {
            await selectThread(id)
        }
        setRoute(.chat)
    }

    public func createThread(title: String = "New Chat", mode: ConversationMode = .agent) async {
        await finishActiveResponseBeforeTransition()
        dismissWorkspaceListingInspector()
        workbenchStore.dismissDiffPatchReview()
        reviewDraftStore.discardAll()
        let thread = conversationStore.createThread(
            title: title,
            workspace: workspaceRoot.isEmpty ? nil : workspaceRoot,
            mode: mode
        )
        await projectRuntimeCommand(.switchThread(threadID: thread.id))
        timelineStore.reset()
        resetAgentActivityForConversation()
        await rebuildSession(keepingHistory: false)
    }

    /// Makes every message entry point safe to use without requiring the user
    /// to press New Chat first. If an older buggy flow already produced blocks
    /// without a thread, attach them to the new metadata instead of discarding
    /// the visible conversation.
    private func ensureActiveThread() async {
        let hasOrphanedBlocks = !blocks.isEmpty
        let created = conversationStore.ensureActiveThread(
            workspace: workspaceRoot.isEmpty ? nil : workspaceRoot,
            mode: composerViewModel.mode
        )
        guard created else { return }

        if let threadID = activeThreadId {
            await projectRuntimeCommand(.switchThread(threadID: threadID))
        }
        guard !hasOrphanedBlocks else { return }
        timelineStore.reset()
        resetAgentActivityForConversation()
        await rebuildSession(keepingHistory: false)
    }

    /// Generates a concise title from the first user prompt using the Apple
    /// on-device model, then applies it to the thread that initiated the request.
    public func generateTitle(from prompt: String, for threadID: String? = nil) async {
        // Capture identity before inference: the active conversation can change
        // while the on-device model streams a title in the background.
        guard let threadID = threadID ?? activeThreadId,
              threads.contains(where: { $0.id == threadID && $0.title == "New Chat" }) else { return }

        if let title = await modelRuntimeStore.generateConversationTitle(from: prompt) {
            applyGeneratedTitle(title, to: threadID)
        }
    }

    /// Commits an asynchronously generated title by stable identity. Re-finding
    /// the value prevents array insertions or sorting changes from targeting a
    /// different conversation, and preserves a title the user renamed meanwhile.
    func applyGeneratedTitle(_ title: String, to threadID: String) {
        conversationStore.applyGeneratedTitle(title, to: threadID)
    }

    // MARK: - Session Persistence

    /// Saves the active thread and its blocks to `~/.turbocode/sessions/<id>.json`.
    public func persistSession(for threadId: String) async {
        await sessionCoordinator.persistActiveSession(id: threadId)
    }

    /// Persists catalog-only changes without replacing a non-active thread's
    /// timeline. Active drafts use the full session snapshot; older threads
    /// retain their durable blocks and transcript while only metadata changes.
    private func persistConversationMetadata(for threadID: String) async {
        await sessionCoordinator.persistMetadata(id: threadID)
    }

    /// Persists a delayed generated title without resnapshotting the active
    /// timeline. The response operation has already saved its durable blocks
    /// before releasing ownership; updating only metadata prevents a title
    /// completion from capturing a newer turn while that turn is streaming.
    private func persistGeneratedTitleMetadata(for threadID: String) async {
        await sessionCoordinator.persistGeneratedTitle(id: threadID)
    }

    /// Loads all session files and populates the thread list.
    public func restoreSessions() async {
        await sessionCoordinator.restoreCatalog()
    }

    /// Fully restores a past session with its blocks.
    public func restoreSession(id: String) async {
        let startedAt = Date()
        await finishActiveResponseBeforeTransition()
        guard let snapshot = await sessionCoordinator.load(id: id),
              let _ = threads.firstIndex(where: { $0.id == id }) else { return }
        dismissWorkspaceListingInspector()
        workbenchStore.dismissDiffPatchReview()
        reviewDraftStore.discardAll()
        conversationStore.activeThreadID = id
        await projectRuntimeCommand(.restore(threadID: id))
        timelineStore.restore(snapshot.blocks)
        resetAgentActivityForConversation()
        if let wp = snapshot.conversation.workspace, workspaceRoot != wp {
            // Restoration adopts the persisted root without starting the
            // interactive workspace transition a second time.
            workspaceStore.root = wp
        }
        await refreshSkillsIfNeeded()
        await restoreModelSelection(snapshot.modelBackend)
        let restoredHistory = snapshot.transcript.map {
            SessionRebuildHistory.prepare(
                $0,
                keepingHistory: true,
                discardingCapabilityContext: false
            )
        } ?? SessionRebuildHistory.fromVisibleBlocks(snapshot.blocks)
        await rebuildSession(keepingHistory: false, restoringHistory: restoredHistory)
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
    }

    private func restoreModelSelection(_ identifier: String) async {
        await profileSelectionCoordinator.restoreModelSelection(identifier)
    }

    public func renameThread(id: String, title: String) async {
        conversationStore.renameThread(id: id, title: title)
        await persistConversationMetadata(for: id)
    }

    public func pinThread(id: String, pinned: Bool) async {
        conversationStore.pinThread(id: id, pinned: pinned)
        await persistConversationMetadata(for: id)
    }

    public func archiveThread(id: String) async {
        conversationStore.archiveThread(id: id)
        await persistConversationMetadata(for: id)
    }

    public func deleteThread(id: String) async {
        let deletesActiveThread = activeThreadId == id
        if deletesActiveThread {
            // Deletion is a runtime transition too: wait for response,
            // selection, and handoff tasks through the shared quiescence
            // barrier before removing the conversation they may still touch.
            await finishActiveResponseBeforeTransition()
        }

        let nextThreadID: String?
        do {
            nextThreadID = try await sessionCoordinator.delete(id: id)
        } catch {
            // Keep the visible row when durable deletion fails; pretending the
            // operation succeeded would make it reappear on the next launch.
            self.error = "Could not delete the conversation: \(error.localizedDescription)"
            return
        }
        self.error = nil

        // Preserve the selection captured before awaiting an in-flight response:
        // the original transition always cleared that conversation's timeline.
        guard deletesActiveThread else { return }

        conversationStore.activeThreadID = nil
        await projectRuntimeCommand(.switchThread(threadID: nil))
        timelineStore.reset()
        resetAgentActivityForConversation()
        reviewDraftStore.discardAll()

        if let nextThreadID {
            await restoreSession(id: nextThreadID)
            if activeThreadId == nil {
                // A never-persisted draft has no snapshot to restore but remains
                // a valid next selection with a fresh model session.
                conversationStore.activeThreadID = nextThreadID
                await rebuildSession(keepingHistory: false)
            }
        } else {
            await rebuildSession(keepingHistory: false)
        }
    }

    /// Removes a workspace from TurboCode and deletes only its persisted chats.
    /// The workspace directory and all project files are left untouched.
    public func removeWorkspace(_ path: String) async {
        await finishActiveResponseBeforeTransition()
        let activeThreadBeforeRemoval = activeThreadId
        let persistenceRemoval = await sessionCoordinator.removeWorkspace(path)
        let removedActiveThread = activeThreadBeforeRemoval.map(
            persistenceRemoval.deletedConversationIDs.contains
        ) ?? false
        let removedActiveWorkspace = workspaceStore.removeWorkspace(path)

        if removedActiveThread {
            await projectRuntimeCommand(.switchThread(threadID: nil))
            timelineStore.reset()
            resetAgentActivityForConversation()
        }

        if removedActiveWorkspace {
            workbenchStore.rightPanelMode = nil
            await rebuildSession(keepingHistory: false)
        }

        if !persistenceRemoval.deletionErrors.isEmpty {
            let details = persistenceRemoval.deletionErrors.joined(separator: "; ")
            error = "Some workspace chats could not be removed: \(details)"
        }
    }

    public func restoreThread(id: String) async {
        conversationStore.restoreThread(id: id)
        await persistConversationMetadata(for: id)
    }

    /// Open a folder picker and set workspaceRoot.
    public func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a workspace folder for the AI agent"
        if !workspaceRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workspaceRoot)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await setWorkspace(url.path) }
    }

    /// Switch to a previously opened workspace by path.
    public func switchToWorkspace(_ path: String) {
        Task { await setWorkspace(path) }
    }

    /// Internal: configure workspace, rebuild session, refresh git state.
    private func setWorkspace(_ path: String) async {
        await finishActiveResponseBeforeTransition()
        workspaceStore.selectWorkspace(path)

        await refreshSkillsIfNeeded()
        await rebuildSession(discardingCapabilityContext: true)
        // The inspector is opt-in: changing workspace must not open it.
        workbenchStore.rightPanelMode = nil
        Task { await reloadDiffs() }
        Task { await refreshGitBranches() }
    }

    /// Clear the workspace selection.
    public func clearWorkspace() {
        Task {
            await finishActiveResponseBeforeTransition()
            workspaceStore.clearWorkspace()
            await rebuildSession(discardingCapabilityContext: true)
            workbenchStore.rightPanelMode = nil
        }
    }

    public func sendMessage(_ text: String) async {
        // Slash commands are application actions. Handling them here keeps
        // local documentation and worker execution independent of the active
        // profile's model-facing tool catalog.
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/documentation" {
            await openDocumentation()
            return
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/compact" {
            await compactContext()
            return
        }
        if let taskGoal = Self.taskCommandGoal(from: text) {
            await runIndependentTask(taskGoal)
            return
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/task" {
            error = "Use /task followed by the task instructions."
            return
        }
        presentationViewModel.clearCompactionNotice()
        await refreshSkillsIfNeeded()
        if activeBackend != .codex,
           modelRuntimeStore.workspaceInstructionsChanged(in: workspaceRoot) {
            // LanguageModelSession instructions are immutable. Preserve visible
            // history while replacing only the stale system-instruction prefix.
            await rebuildSession()
        }
        guard let promptText = modelRuntimeStore.resolvedPrompt(
            for: text
        ) else { return }
        await sendMessage(text, promptText: promptText, visibleInTimeline: true)
    }

    /// Sends all valid inline annotations as one explicit user request. The
    /// compact timeline text remains readable while the model receives stable
    /// reviewed excerpts and sides through the provider-neutral prompt path.
    func sendReviewComments() async {
        guard !busy, activeProfileCanSend else { return }
        guard reviewDraftStore.outdatedCount == 0 else {
            error = "Refresh or remove outdated review comments before sending."
            return
        }
        guard let request = ReviewRequestBuilder.make(
            comments: reviewDraftStore.comments
        ) else { return }

        await refreshSkillsIfNeeded()
        if activeBackend != .codex,
           modelRuntimeStore.workspaceInstructionsChanged(in: workspaceRoot) {
            await rebuildSession()
        }
        guard let promptText = modelRuntimeStore.resolvedPrompt(
            for: request.promptText
        ) else { return }

        // The visible user block is now the durable receipt for this ephemeral
        // draft, so clearing before inference cannot lose the authored review.
        reviewDraftStore.discardAll()
        workbenchStore.rightPanelMode = nil
        await sendMessage(
            request.displayText,
            promptText: promptText,
            visibleInTimeline: true
        )
    }

    /// Presents the official guide without starting a model response. The
    /// fixed overview query mirrors the guide tool's normal broad product
    /// question while retaining its native structured widget and source chips.
    public func openDocumentation() async {
        guard !busy else { return }
        do {
            let documentation = ProductDocumentationStore.live
            try documentation.installBundledDocumentation()
            let resolution = try TurboCodeGuideTool(store: documentation)
                .resolve(query: "What can TurboCode do?")
            await ensureActiveThread()
            timelineStore.presentProductGuide(
                resolution.presentation,
                markdown: resolution.markdown
            )
            if let threadID = activeThreadId {
                conversationStore.touchThread(id: threadID)
                await persistSession(for: threadID)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Compacts only the active local Llama conversation. Apple on-device
    /// compaction has its own automatic path and is intentionally untouched.
    private func compactContext() async {
        guard !busy else { return }
        guard activeBackend == .llamaServer else {
            error = "/compact is available only for local Llama models."
            return
        }

        let turnCount = SessionRebuildHistory.userTurnCount(
            in: modelRuntimeStore.transcript
        )
        let maximumCharacters = SessionRebuildHistory.localCompactionCharacterLimit(
            contextWindowTokens: activeRemoteModel?.contextWindowTokens
        )
        guard let compaction = SessionRebuildHistory.localCompaction(
            from: blocks,
            maximumCharacters: maximumCharacters
        ) else {
            error = "Nothing to compact yet."
            return
        }

        error = nil
        await ensureActiveThread()
        timelineStore.presentCompaction(compaction.summary)
        presentationViewModel.presentCompactionNotice(
            LocalCompactionNotice(
                sourceCharacters: compaction.sourceCharacters,
                retainedCharacters: compaction.retainedCharacters
            )
        )
        await rebuildSession(restoringHistory: compaction.history)

        await AgentDiagnosticsRecorder.shared.recordLocalCompaction(
            backend: activeBackend,
            turnCount: turnCount,
            sourceCharacters: compaction.sourceCharacters,
            retainedCharacters: compaction.retainedCharacters
        )

        if let threadID = activeThreadId {
            conversationStore.touchThread(id: threadID)
            await persistSession(for: threadID)
        }
    }

    func isIncompleteSkillCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "/skill"
    }

    func isIncompleteTaskCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "/task"
    }

    func isLocalCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "/documentation"
            || trimmed == "/task"
            || trimmed == "/compact"
            || Self.taskCommandGoal(from: trimmed) != nil
    }

    /// Runs `/task <instructions>` through the configured worker directly.
    /// The active profile does not need to advertise `delegate_task`, because
    /// this is an explicit application command rather than model tool use.
    private func runIndependentTask(_ goal: String) async {
        await ensureActiveThread()
        await independentTaskCoordinator.run(goal: goal)
    }

    private static func taskCommandGoal(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/task ") else { return nil }
        let goal = String(trimmed.dropFirst("/task ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? nil : goal
    }

    public func reloadSkills() async {
        await refreshSkillsIfNeeded(forceRebuild: true)
    }

    func applyAgentTuning(_ value: AgentTuningConfig) async {
        guard modelRuntimeStore.applyAgentTuning(value) else { return }
        await rebuildSession(discardingCapabilityContext: true)
    }

    private func refreshSkillsIfNeeded(forceRebuild: Bool = false) async {
        guard modelRuntimeStore.refreshSkills(
            force: forceRebuild,
            workspaceRoot: workspaceRoot
        ) else { return }
        await rebuildSession(discardingCapabilityContext: true)
    }

    private func sendMessage(
        _ text: String,
        promptText: String? = nil,
        visibleInTimeline: Bool
    ) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !busy,
              activeProfileCanSend else { return }

        await compactOnDeviceContextIfNeeded()
        let effectivePrompt = promptText ?? text
        await ensureActiveThread()
        // One identity follows the accepted prompt through either provider so
        // late callbacks cannot be mistaken for the next user turn.
        let turnID = TurnID()
        let titleThreadID = activeThreadId
        // Capture routing before detached execution. The provider task receives
        // an immutable value and never reaches back into MainActor UI state to
        // decide which backend owns this turn.
        let responseBackend = activeBackend
        await agentRuntime.runOperation(
            turnID: turnID,
            operation: { [weak self] in
                guard let self else { return }
                if responseBackend == .codex {
                    await self.performCodexSendMessage(
                        displayText: text,
                        promptText: effectivePrompt,
                        visibleInTimeline: visibleInTimeline,
                        turnID: turnID
                    )
                } else {
                    await self.performSendMessage(
                        displayText: text,
                        promptText: effectivePrompt,
                        visibleInTimeline: visibleInTimeline,
                        turnID: turnID
                    )
                }
            },
            afterRelease: { [weak self] in
                guard visibleInTimeline,
                      let self,
                      let titleThreadID else { return }
                // Title inference is optional catalog polish. It deliberately
                // starts after response ownership is released so a stalled
                // Apple title session cannot leave the composer on Stop.
                await self.generateTitle(from: text, for: titleThreadID)
                await self.persistGeneratedTitleMetadata(for: titleThreadID)
            }
        )
    }

    /// Compacts only at a turn boundary, when the previous on-device context
    /// has reached eight question/answer turns. The active session is rebuilt
    /// from a concise handoff so the ninth question starts with usable context.
    private func compactOnDeviceContextIfNeeded() async {
        guard activeBackend == .foundationApple else { return }
        let turnCount = SessionRebuildHistory.userTurnCount(
            in: modelRuntimeStore.transcript
        )
        guard turnCount >= SessionRebuildHistory.onDeviceCompactionThreshold,
              let compaction = SessionRebuildHistory.onDeviceCompaction(from: blocks)
        else { return }

        timelineStore.presentCompaction(compaction.summary)
        await rebuildSession(restoringHistory: compaction.history)
        Task {
            await AgentDiagnosticsRecorder.shared.recordCompaction(
                turnCount: turnCount,
                retainedCharacters: compaction.summary.count
            )
        }
    }

    /// Runs one turn through Codex App Server while preserving TurboCode's
    /// timeline contract. Visual file-change mapping is intentionally a later
    /// adapter layer; this foundation handles text, reasoning and cancellation.
    /// Dynamic coordinator profiles also forward their isolated Codex choices
    /// without changing the direct-Codex composer preference.
    private func performCodexSendMessage(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool,
        turnID: TurnID
    ) async {
        error = nil
        guard let turboThreadID = activeThreadId else {
            self.error = "TurboCode could not create the conversation."
            return
        }
        let result = await responseCoordinator.performCodex(
            displayText: displayText,
            promptText: promptText,
            visibleInTimeline: visibleInTimeline,
            turnID: turnID,
            turboThreadID: turboThreadID,
            workspaceRoot: workspaceRoot,
            workspaceName: workspaceRoot.isEmpty ? nil : workspaceLabel,
            mode: orchestratorMode,
            workspaceKind: diagnosticsWorkspaceKind,
            agentTuning: agentTuning,
            availableSkills: DynamicProfileRuntimeSelection.skills(
                from: modelRuntimeStore.availableSkills,
                profile: activeDynamicProfile,
                safariMCPEnabled: agentTuning.experimental.safariMCPEnabled
            ),
            codexModelID: activeDynamicProfile?.codexModelID,
            codexReasoningEffort:
                activeDynamicProfile?.codexReasoningEffort,
            delegationInvoker: modelRuntimeStore.makeDelegateInvoker(
                workspaceRoot: workspaceRoot,
                events: responseCoordinator.modelSessionEvents
            ),
            modelName: composerModel
        )
        modelRuntimeStore.composerModel = activeDynamicProfile?.name
            ?? "Codex · \(codexDisplayName)"
        error = result.errorMessage
        if result.touchedConversation {
            conversationStore.touchThread(id: turboThreadID)
        }
        // A skill created by skill-creator becomes available to the next turn
        // without requiring an app restart or a manual Skills reload.
        await refreshSkillsIfNeeded()
        await persistSession(for: turboThreadID)
    }

    private func performSendMessage(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool,
        turnID: TurnID
    ) async {
        let conversationID = activeThreadId
        presentationViewModel.runtimeStatus = .ready
        error = nil
        let result = await responseCoordinator.performNative(
            displayText: displayText,
            promptText: promptText,
            visibleInTimeline: visibleInTimeline,
            turnID: turnID,
            blocks: blocks,
            backend: activeBackend,
            mode: orchestratorMode,
            workspaceKind: diagnosticsWorkspaceKind,
            workspaceRoot: workspaceRoot,
            modelName: composerModel,
            serverURL: activeBackend == .llamaServer
                ? activeRemoteModel?.url
                : nil,
            contextChanged: { [weak self] usage in
                guard let self, self.activeBackend == .llamaServer else { return }
                self.presentationViewModel.setLlamaContextUsage(usage)
            }
        )
        error = result.errorMessage
        if result.touchedConversation, let conversationID {
            conversationStore.touchThread(id: conversationID)
        }
        // A skill created by skill-creator becomes available to the next turn
        // without requiring an app restart or a manual Skills reload.
        await refreshSkillsIfNeeded()
        if let conversationID, activeThreadId == conversationID {
            await persistSession(for: conversationID)
        }
    }

    public func interrupt() async {
        await agentRuntime.requestOperationCancellation()
        let shouldInterruptCodex = activeBackend == .codex
        let approvals = toolInteractionStore.takeAllApprovals()
        toolInteractionStore.clearActivities()
        if shouldInterruptCodex {
            await codexRuntimeStore.interrupt()
        }
        // Stop is terminal for the current response. Reject every approval
        // removed from its transient UI so neither a native continuation
        // nor a Codex server request remains orphaned.
        for request in approvals {
            do {
                if try await codexRuntimeStore.resolveApproval(
                    id: request.id,
                    approved: false
                ) {
                    continue
                }
            } catch {
                // The local registry remains the fallback when the request
                // did not originate from Codex or its turn already ended.
            }
            _ = await ToolApprovalRegistry.shared.reject(id: request.id)
        }
    }

#if DEBUG
    public func runActiveEditingBenchmark() async {
        guard !benchmarkRunning, !busy else { return }
        benchmarkRunning = true
        benchmarkStatus = "Running \(activeBackend.rawValue) editing benchmark..."
        defer { benchmarkRunning = false }

        let summary = await modelRuntimeStore.runEditingBenchmark()
        benchmarkStatus = summary
        print("[Benchmark] \(summary)")
    }

    public func printToolFailureSummary() async {
        let summary = await AgentDiagnosticsRecorder.shared.failureSummary()
        print("[Diagnostics] \(summary)")
    }

    public func printRuntimeBaselineSummary() async {
        let summary = await AgentDiagnosticsRecorder.shared.runtimeBaselineSummary()
        print("[Diagnostics] Runtime baseline 0.3.4\n\(summary.summary)")
    }
#endif

    private var diagnosticsWorkspaceKind: String {
        guard !workspaceRoot.isEmpty else { return "none" }
        let marker = URL(fileURLWithPath: workspaceRoot).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: marker.path) ? "git" : "nonGit"
    }

    /// Approve a pending tool operation, execute the exact registered action,
    /// then inform the model that the action completed.
    public func approveAction() {
        guard let request = toolInteractionStore.takePendingApproval() else { return }
        let conversationID = activeThreadId

        Task {
            do {
                if try await codexRuntimeStore.resolveApproval(
                    id: request.id,
                    approved: true
                ) {
                    return
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
            let resolution = await ToolApprovalRegistry.shared.approve(id: request.id)
            if resolution.requiresModelFollowUp {
                await sendInternalMessageWhenIdle(
                    conversationID: conversationID,
                    text: """
                [User approved tool action]
                Operation: \(request.operation)
                Path: \(request.path)
                Result:
                \(resolution.result)
                """
                )
            }
        }
    }

    /// Reject a pending tool operation.
    public func rejectAction() {
        guard let request = toolInteractionStore.takePendingApproval() else { return }
        let conversationID = activeThreadId
        Task {
            do {
                if try await codexRuntimeStore.resolveApproval(
                    id: request.id,
                    approved: false
                ) {
                    return
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
            if request.operation == "diffPatch" {
                updateDiffPatchBlock(id: request.id, status: .rejected)
            }
            let resolution = await ToolApprovalRegistry.shared.reject(id: request.id)
            if resolution.requiresModelFollowUp {
                await sendInternalMessageWhenIdle(
                    conversationID: conversationID,
                    text: "[User rejected tool action: \(request.summary). Do NOT perform this action.]"
                )
            }
        }
    }

    /// Receives approval requests directly from ToolApprovalRegistry. Transcript
    /// parsing remains a compatibility fallback for external model adapters.
    public func presentApproval(_ request: ApprovalRequest) {
        toolInteractionStore.enqueueApproval(request)
    }

    public func dismissApproval(id: String) {
        toolInteractionStore.dismissApproval(id: id)
    }

    private func sendInternalMessageWhenIdle(
        conversationID: String?,
        text: String
    ) async {
        await agentRuntime.waitUntilIdle()
        guard !Task.isCancelled,
              activeThreadId == conversationID else { return }
        await sendMessage(text, visibleInTimeline: false)
    }

    public func beginDiffPatchBlock(
        id: String,
        patch: String,
        files: [DiffPatchFileChange],
        reviewFiles: [DiffReviewFileSnapshot] = [],
        status: DiffPatchStatus
    ) {
        reviewCoordinator.beginDiffPatch(
            id: id,
            editGroupID: responseCoordinator.activeEditGroupID,
            workspaceRoot: workspaceRoot,
            patch: patch,
            files: files,
            reviewFiles: reviewFiles,
            status: status
        )
    }

    public func updateDiffPatchBlock(
        id: String,
        status: DiffPatchStatus,
        errorMessage: String? = nil
    ) {
        reviewCoordinator.updateDiffPatch(
            id: id,
            status: status,
            errorMessage: errorMessage
        )
    }

    public func reviewDiffPatch(_ id: String) {
        reviewCoordinator.reviewDiffPatch(id)
    }

    /// Opens a native full-file review from stable workbench state. The
    /// timeline fallback remains available through `reviewDiffPatch(_:)`.
    func presentDiffPatchReview(_ id: String) {
        reviewCoordinator.presentDiffPatchReview(id)
    }

    public func presentGitCommit(_ receipt: GitCommitBlock) {
        reviewCoordinator.presentGitCommit(receipt)
    }

    /// Publishes the immutable status snapshot produced by an explicit model
    /// tool call; background workspace refreshes deliberately remain silent.
    public func presentGitStatus(_ status: GitStatusBlock) {
        timelineStore.presentGitStatus(status)
    }

    public func reviewGitCommit(_ id: String) {
        reviewCoordinator.reviewGitCommit(id)
    }

    /// Shows the immutable snapshot associated with one timeline receipt. The
    /// inspector never rereads the filesystem, preserving conversational history.
    public func reviewWorkspaceListing(_ id: String) {
        reviewCoordinator.reviewWorkspaceListing(id)
    }

    /// Returns whether a structured result references a receipt that still
    /// exists in the current conversation timeline.
    func canOpenActivityReceipt(_ receiptID: String) -> Bool {
        activityReceiptBlock(for: receiptID) != nil
    }

    /// Opens an existing receipt through its native review surface. Activity
    /// holds identifiers only and never copies receipt content into its state.
    @discardableResult
    func openActivityReceipt(_ receiptID: String) -> Bool {
        guard let block = activityReceiptBlock(for: receiptID) else {
            return false
        }
        if block.diffPatch != nil {
            reviewDiffPatch(block.id)
            return true
        }
        if block.gitCommit != nil {
            reviewGitCommit(block.id)
            return true
        }
        if block.workspaceListing != nil {
            reviewWorkspaceListing(block.id)
            return true
        }
        return false
    }

    /// Dismisses only the transient workspace snapshot. Other inspectors are
    /// persistent workbench modes and must not close when the canvas is clicked.
    func dismissWorkspaceListingInspector() {
        workbenchStore.dismissWorkspaceListingInspector()
    }

    public func undoGitCommit(_ id: String) {
        reviewCoordinator.undoGitCommit(id) { [weak self] in
            guard let self,
                  let threadID = self.activeThreadId else { return }
            await self.persistSession(for: threadID)
        }
    }

    public func undoDiffPatch(_ id: String) {
        reviewCoordinator.undoDiffPatch(id) { [weak self] in
            guard let self,
                  let threadID = self.activeThreadId else { return }
            await self.persistSession(for: threadID)
        }
    }

    public func setRoute(_ route: AppRoute) {
        workbenchStore.setRoute(route)
    }

    /// Opens the profile editor. Delegation is configured by including the
    /// `delegate_task` capability rather than by selecting a separate route.
    func requestProfileCreation() {
        workbenchStore.requestProfileCreation(role: .direct)
    }

    /// Compatibility entry point for older callers that want the delegation
    /// capability preselected in the creation sheet.
    func requestCoordinatorProfileCreation() {
        workbenchStore.requestProfileCreation(role: .coordinatorWorker)
    }

    func consumeProfileCreationRequest() -> ProfileExecutionRole? {
        workbenchStore.consumeProfileCreationRequest()
    }

    public func toggleRightPanel(_ mode: RightPanelMode) {
        // The Changes panel renders a snapshot of workspace diffs, so refresh it
        // whenever the panel opens. Files staged or modified outside TurboCode
        // would otherwise stay invisible until a manual refresh or workspace
        // switch. Toggling the panel closed must not trigger a reload.
        let opensChangesPanel = mode == .changes && workbenchStore.rightPanelMode != .changes
        workbenchStore.toggleRightPanel(mode)
        if opensChangesPanel {
            Task { await reloadDiffs() }
        }
    }

    /// Toggles the user-owned project terminal. This presentation command is
    /// intentionally unrelated to model tool availability or delegation.
    public func toggleTerminal() {
        workbenchStore.toggleTerminal()
    }

    /// Closes the system inspector without discarding its conversation-local
    /// data, allowing the user to reopen the completed Activity summary.
    func closeRightPanel() {
        workbenchStore.rightPanelMode = nil
    }

    var diffPatchReviewPresentation: DiffPatchReviewPresentation? {
        get { workbenchStore.inspectedDiffPatchReview }
        set { workbenchStore.inspectedDiffPatchReview = newValue }
    }

    func dismissDiffPatchReview() {
        workbenchStore.dismissDiffPatchReview()
    }

    public func toggleLeftSidebar() {
        workbenchStore.toggleLeftSidebar()
    }

    private func resetAgentActivityForConversation() {
        agentActivityStore.reset()
        if workbenchStore.rightPanelMode == .activity {
            workbenchStore.rightPanelMode = nil
        }
    }

    /// Projects context transitions through the runtime owner so the timeline
    /// never retains a stale thread or backend after navigation settles.
    private func projectRuntimeCommand(_ command: RuntimeCommand) async {
        _ = await agentRuntime.apply(command)
    }

    /// Projects only events accepted by the runtime owner. `/task` is an app
    /// command rather than a backend session, so the facade is its adapter and
    /// must still pass through the same stale-TurnID gate as native and Codex.
    @discardableResult
    private func projectRuntimeEvent(_ event: AgentRuntimeEvent) async -> Bool {
        await agentRuntime.apply(event)
    }

    /// Navigation and workspace changes are transaction boundaries for a live
    /// response. Waiting for the cancelled task to finish lets its final
    /// persistence pass target the old conversation before the new timeline or
    /// workspace is installed.
    private func finishActiveResponseBeforeTransition() async {
        await agentRuntime.beginQuiescence()
        await profileSelectionCoordinator.cancelAndWaitForTransitions()
        await agentRuntime.cancelAndWaitForOperation()
        await agentRuntime.endQuiescence()
    }

    private func activityReceiptBlock(for receiptID: String) -> ChatBlock? {
        blocks.first { block in
            block.id == receiptID
                || block.workspaceListing?.toolCallID == receiptID
                || block.gitCommit?.hash == receiptID
        }
    }

}
