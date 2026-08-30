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

    /// Keeps detached plugin surfaces associated with their timeline block.
    /// The receipt is intentionally in-memory only: closing a detached window
    /// can restore the exact widget without adding window state to sessions.
    public private(set) var detachedPluginWidgets: [String: TypeScriptPluginWidgetReceipt] = [:]

    public func detachPluginWidget(
        _ widget: TypeScriptPluginWidgetReceipt,
        blockID: String
    ) {
        detachedPluginWidgets[blockID] = widget
    }

    public func restorePluginWidget(blockID: String) {
        detachedPluginWidgets.removeValue(forKey: blockID)
    }

    public func isPluginWidgetDetached(blockID: String) -> Bool {
        detachedPluginWidgets[blockID] != nil
    }

    public func detachedPluginWidget(for blockID: String) -> TypeScriptPluginWidgetReceipt? {
        detachedPluginWidgets[blockID]
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
    let typeScriptPluginActivationStore: TypeScriptPluginActivationStore
    let modelRuntimeStore: ModelRuntimeStore
    let agentRuntime: AgentRuntime
    private let llmRuntime: LLMRuntime
    let onDeviceToolCallingSupported: Bool
    let responseCoordinator: ChatResponseCoordinator
    private let sessionCoordinator: ConversationSessionCoordinator
    private let conversationPersistence: ConversationPersistenceService
    private let profileSelectionCoordinator: ProfileSelectionCoordinator
    private let conversationLifecycleCoordinator: ConversationLifecycleCoordinator
    private let workspaceLifecycleCoordinator: WorkspaceLifecycleCoordinator
    private let independentTaskCoordinator: IndependentTaskCoordinator
    private let messageSendCoordinator: MessageSendCoordinator
    /// Composition-only bridge for the isolated Editorial Desk. The feature
    /// receives its narrow ports rather than the ChatStore facade itself.
    let editorialDeskAssembly: EditorialDeskAssembly
    private let reviewCoordinator: ReviewCoordinator

    /// Composition-only command router. Command parsing and dispatch live in
    /// the composer service; this facade property only wires those actions to
    /// the existing application coordinators without owning their logic.
    @ObservationIgnored
    private(set) lazy var composerCommandRouter: ComposerCommandRouter = {
        ComposerCommandRouter(
            actions: ComposerCommandActions(
                openDocumentation: { [weak self] in
                    await self?.openDocumentation()
                },
                compact: { [weak self] in
                    await self?.compactContext()
                },
                reload: { [weak self] in
                    await self?.reloadPluginsPreservingSession()
                },
                runTask: { [weak self] goal in
                    await self?.runIndependentTask(goal)
                },
                reportError: { [weak self] message in
                    self?.presentComposerError(message)
                }
            )
        )
    }()
    // MARK: - Onboarding

    /// Ensures the current `~/.turbocode/` layout exists and applies additive migrations.
    public func ensureOnboarding() async {
        do {
            try TurboCodeConfig.shared.performOnboarding()
            if let sdkSource = TypeScriptPluginProjectService.liveSDKSourceURL() {
                _ = try TypeScriptPluginProjectService.live().bootstrapSDK(
                    from: sdkSource
                )
            }
            modelRuntimeStore.applyOnboarding(
                tuning: try TurboCodeConfig.shared.loadAgentTuning(),
                workspaceRoot: workspaceRoot
            )
            // Keep the process gate and provider snapshot aligned with the
            // persisted setting before any session is rebuilt or used.
            let pluginsEnabled = modelRuntimeStore
                .agentTuning
                .experimental
                .thirdPartyPluginsEnabled
            await typeScriptPluginActivationStore.setEnabled(pluginsEnabled)
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
        diffPatchService: any DiffPatchApplying = DiffPatchService(),
        workspaceDefaults: UserDefaults = .standard
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
            codexRuntime: codexRuntime
        )
        let llmRuntime = LLMRuntime(
            sessionFactory: llmSessionFactory,
            foundationModelsBootstrap:
                modelRuntime.foundationModelsBootstrapConfiguration
        )
        let titleGenerator = FoundationModelsConversationTitleGenerator()
        let invokerFactory = AgentTaskInvokerFactory()
        let workspace = WorkspaceStore(
            gitService: gitService,
            reviewDraftStore: reviewDraft,
            defaults: workspaceDefaults
        )
        let workbench = WorkbenchStore()
        let conversations = ConversationStore()
        let typeScriptPluginActivation = TypeScriptPluginActivationStore(
            sdkPackageURL: TurboCodeConfig.shared.sdkDirectoryURL
                .appendingPathComponent("@granvalenti", isDirectory: true)
                .appendingPathComponent("turbocode-sdk", isDirectory: true),
            sessionTranscript: {
                let thread = conversations.activeThreadID.flatMap {
                    conversations.conversation(id: $0)
                }
                return TypeScriptPluginSessionTranscript(
                    sessionID: thread?.id,
                    title: thread?.title,
                    blocks: timeline.blocks
                ).jsonValue
            }
        )
        let conversationPersistence = ConversationPersistenceService(
            repository: conversationRepository
        )
        self.conversationStore = conversations
        let sessionCoordinator = ConversationSessionCoordinator(
            conversations: conversations,
            timeline: timeline,
            modelRuntime: modelRuntime,
            llmRuntime: llmRuntime,
            persistence: conversationPersistence
        )
        self.sessionCoordinator = sessionCoordinator
        self.conversationPersistence = conversationPersistence
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
        self.typeScriptPluginActivationStore = typeScriptPluginActivation
        self.modelRuntimeStore = modelRuntime
        self.agentRuntime = agentRuntime
        self.llmRuntime = llmRuntime
        self.onDeviceToolCallingSupported =
            FoundationModelsCapabilities.onDeviceSupportsToolCalling
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
            llmRuntime: llmRuntime,
            runtimeProjection: runtimeProjection,
            responseCoordinator: responseCoordinator
        )
        self.profileSelectionCoordinator = profileSelectionCoordinator
        let transitionBarrier = RuntimeTransitionBarrier(
            runtime: agentRuntime,
            profiles: profileSelectionCoordinator
        )
        let conversationLifecycleCoordinator = ConversationLifecycleCoordinator(
            conversations: conversations,
            timeline: timeline,
            activity: agentActivity,
            workbench: workbench,
            workspace: workspace,
            composer: composer,
            reviewDrafts: reviewDraft,
            presentation: presentation,
            runtime: agentRuntime,
            profiles: profileSelectionCoordinator,
            sessions: sessionCoordinator,
            transitionBarrier: transitionBarrier
        )
        self.conversationLifecycleCoordinator = conversationLifecycleCoordinator
        self.workspaceLifecycleCoordinator = WorkspaceLifecycleCoordinator(
            workspace: workspace,
            conversations: conversations,
            timeline: timeline,
            activity: agentActivity,
            workbench: workbench,
            presentation: presentation,
            runtime: agentRuntime,
            profiles: profileSelectionCoordinator,
            sessions: sessionCoordinator,
            transitionBarrier: transitionBarrier
        )
        self.independentTaskCoordinator = IndependentTaskCoordinator(
            runtime: agentRuntime,
            runtimeProjection: runtimeProjection,
            responseCoordinator: responseCoordinator,
            invokerFactory: invokerFactory,
            modelRuntime: modelRuntime,
            conversations: conversations,
            timeline: timeline,
            codexRuntime: codexRuntime,
            workspace: workspace,
            presentation: presentation,
            sessions: sessionCoordinator,
            profiles: profileSelectionCoordinator,
            lifecycle: conversationLifecycleCoordinator
        )
        let messageSendCoordinator = MessageSendCoordinator(
            runtime: agentRuntime,
            llmRuntime: llmRuntime,
            titleGenerator: titleGenerator,
            invokerFactory: invokerFactory,
            runtimeProjection: runtimeProjection,
            responseCoordinator: responseCoordinator,
            modelRuntime: modelRuntime,
            codexRuntime: codexRuntime,
            conversations: conversations,
            timeline: timeline,
            workspace: workspace,
            presentation: presentation,
            sessions: sessionCoordinator,
            profiles: profileSelectionCoordinator,
            lifecycle: conversationLifecycleCoordinator
        )
        self.messageSendCoordinator = messageSendCoordinator
        self.editorialDeskAssembly = EditorialDeskAssembly(
            runtime: llmRuntime,
            modelRuntime: modelRuntime,
            codexRuntime: codexRuntime,
            messageSender: messageSendCoordinator
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

    /// Refreshes profile metadata without rebuilding the active provider
    /// session. Composer-owned `/reload` uses this non-invalidating path.
    func reloadProfilesPreservingSession() async {
        await profileSelectionCoordinator.reloadDynamicProfilesPreservingSession()
    }

    /// Restarts plugin processes and refreshes their manifest/tool snapshot
    /// without discarding the visible conversation. `/reload` uses this path
    /// so a newly copied or edited plugin becomes available immediately.
    func reloadPluginsPreservingSession() async {
        await profileSelectionCoordinator.reloadDynamicProfilesPreservingSession()
        await typeScriptPluginActivationStore.shutdown()
        await discoverAndActivateTypeScriptPlugins()
        modelRuntimeStore.setActivePluginTools(
            await typeScriptPluginActivationStore.activeTools()
        )
        await profileSelectionCoordinator.rebuildSession(
            discardingCapabilityContext: true
        )
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
        restoringHistory: [FoundationModelsTranscriptEntry]? = nil
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
        await conversationLifecycleCoordinator.selectThread(id)
    }

    /// Opens a conversation as one navigation transition. Restoring first keeps
    /// SwiftUI from building the previous, potentially large timeline merely to
    /// replace it one run-loop later when leaving a utility destination.
    public func openThread(_ id: String) async {
        await conversationLifecycleCoordinator.openThread(id)
    }

    public func createThread(title: String = "New Chat", mode: ConversationMode = .agent) async {
        await conversationLifecycleCoordinator.createThread(
            title: title,
            mode: mode
        )
    }

    /// Makes every message entry point safe to use without requiring the user
    /// to press New Chat first. If an older buggy flow already produced blocks
    /// without a thread, attach them to the new metadata instead of discarding
    /// the visible conversation.
    private func ensureActiveThread() async {
        await conversationLifecycleCoordinator.ensureActiveThread()
    }

    /// Generates a concise title from the first user prompt using the Apple
    /// on-device model, then applies it to the thread that initiated the request.
    public func generateTitle(from prompt: String, for threadID: String? = nil) async {
        await messageSendCoordinator.generateTitle(
            from: prompt,
            threadID: threadID
        )
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

    /// Loads all session files and populates the thread list.
    public func restoreSessions() async {
        await sessionCoordinator.restoreCatalog()
    }

    /// Fully restores a past session with its blocks.
    public func restoreSession(id: String) async {
        await conversationLifecycleCoordinator.restoreSession(id: id)
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
        await conversationLifecycleCoordinator.deleteThread(id: id)
    }

    /// Exports only durable JSON snapshots; no workspace directory is read or
    /// modified by the sidebar sharing flow.
    func exportConversationJSON(ids: [String]) async throws -> [ConversationExportItem] {
        try await conversationPersistence.exportJSON(ids: ids)
    }

    /// Removes a workspace from TurboCode and deletes only its persisted chats.
    /// The workspace directory and all project files are left untouched.
    public func removeWorkspace(_ path: String) async {
        await workspaceLifecycleCoordinator.removeWorkspace(path)
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
        Task { await switchToWorkspace(url.path) }
    }

    /// Switch to a previously opened workspace by path.
    public func switchToWorkspace(_ path: String) async {
        await workspaceLifecycleCoordinator.selectWorkspace(path)
    }

    /// Clear the workspace selection.
    public func clearWorkspace() async {
        await workspaceLifecycleCoordinator.clearWorkspace()
    }

    public func sendMessage(_ text: String) async {
        presentationViewModel.clearCompactionNotice()
        guard let promptText = await messageSendCoordinator.preparePrompt(
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

        guard let promptText = await messageSendCoordinator.preparePrompt(
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
    func compactContext() async {
        guard !busy else { return }
        guard activeBackend == .llamaServer else {
            error = "/compact is available only for local Llama models."
            return
        }

        guard let transcript = await sessionCoordinator.foundationModelsTranscript() else {
            error = "The active model session has no transcript checkpoint."
            return
        }
        let turnCount = SessionRebuildHistory.userTurnCount(in: transcript)
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

    /// Runs `/task <instructions>` through the configured worker directly.
    /// The active profile does not need to advertise `delegate_task`, because
    /// this is an explicit application command rather than model tool use.
    func runIndependentTask(_ goal: String) async {
        await independentTaskCoordinator.run(goal: goal)
    }

    func presentComposerError(_ message: String) {
        error = message
    }

    public func reloadSkills() async {
        await messageSendCoordinator.reloadSkills()
    }

    func applyAgentTuning(_ value: AgentTuningConfig) async {
        await messageSendCoordinator.applyAgentTuning(value)
        let enabled = modelRuntimeStore.agentTuning.experimental.thirdPartyPluginsEnabled
        await typeScriptPluginActivationStore.setEnabled(enabled)
        await discoverAndActivateTypeScriptPlugins()
        modelRuntimeStore.setActivePluginTools(
            await typeScriptPluginActivationStore.activeTools()
        )
        await profileSelectionCoordinator.rebuildSession(
            discardingCapabilityContext: true
        )
    }

    /// Loads every valid installed plugin when the global setting permits it.
    /// Discovery failures and individual handshake failures are logged per
    /// plugin so one bad extension never blocks the rest of startup.
    private func discoverAndActivateTypeScriptPlugins() async {
        guard modelRuntimeStore.agentTuning.experimental.thirdPartyPluginsEnabled else {
            return
        }
        let discovery = TypeScriptPluginRegistry.live().discover()
        for failure in discovery.failures {
            print(
                "[TurboCode] Ignoring TypeScript plugin at \(failure.rootURL.path): "
                    + failure.message
            )
        }
        let activationFailures = await typeScriptPluginActivationStore.activateAll(
            discovery.plugins
        )
        for failure in activationFailures {
            print("[TurboCode] Ignoring TypeScript plugin: \(failure)")
        }
    }

    /// Starts a discovered plugin only after the global Settings/Agents trust
    /// switch is enabled. Activation updates the immutable provider snapshot
    /// and rebuilds the current session through the normal profile boundary.
    func activateTypeScriptPlugin(
        _ descriptor: TypeScriptPluginDescriptor
    ) async throws {
        _ = try await typeScriptPluginActivationStore.activate(descriptor)
        modelRuntimeStore.setActivePluginTools(
            await typeScriptPluginActivationStore.activeTools()
        )
        await profileSelectionCoordinator.rebuildSession(
            discardingCapabilityContext: true
        )
    }

    /// Deactivation terminates the child process before removing its tools
    /// from the next provider session snapshot.
    func deactivateTypeScriptPlugin(pluginID: String) async throws {
        try await typeScriptPluginActivationStore.deactivate(pluginID: pluginID)
        modelRuntimeStore.setActivePluginTools(
            await typeScriptPluginActivationStore.activeTools()
        )
        await profileSelectionCoordinator.rebuildSession(
            discardingCapabilityContext: true
        )
    }

    private func refreshSkillsIfNeeded(forceRebuild: Bool = false) async {
        await messageSendCoordinator.refreshSkillsIfNeeded(
            forceRebuild: forceRebuild
        )
    }

    private func sendMessage(
        _ text: String,
        promptText: String? = nil,
        visibleInTimeline: Bool
    ) async {
        _ = await messageSendCoordinator.send(
            displayText: text,
            promptText: promptText ?? text,
            visibleInTimeline: visibleInTimeline
        )
    }

    public func interrupt() async {
        await agentRuntime.requestOperationCancellation()
        let shouldInterruptCodex = activeBackend == .codex
        let approvals = toolInteractionStore.takeAllApprovals()
        toolInteractionStore.clearActivities()
        if shouldInterruptCodex {
            await codexRuntimeStore.interrupt()
        }
        // A cancellation request is only advisory for the detached provider
        // operation. Await its unwind before returning so the runtime
        // projection clears `busy` atomically with the Stop action.
        await agentRuntime.cancelAndWaitForOperation()
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

        let summary = await llmRuntime.runEditingBenchmark(
            configuration: modelRuntimeStore.foundationModelsBootstrapConfiguration,
            reasoningEffort: modelRuntimeStore.reasoningEffort
        )
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
        workspaceRoot transactionRoot: String? = nil,
        status: DiffPatchStatus
    ) {
        reviewCoordinator.beginDiffPatch(
            id: id,
            editGroupID: responseCoordinator.activeEditGroupID,
            workspaceRoot: transactionRoot ?? workspaceRoot,
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

    /// Recognizes a live workspace entry without changing the immutable tool
    /// receipt or exposing Editorial Desk service internals to SwiftUI.
    func editorialDraftSummary(relativePath: String) async -> EditorialDraftSummary? {
        guard !workspaceRoot.isEmpty else { return nil }
        return await editorialDeskAssembly.draftSummary(
            relativePath: relativePath,
            workspaceRoot: workspaceRoot
        )
    }

    func presentEditorialDesk(draftRelativePath: String? = nil) {
        guard !workspaceRoot.isEmpty else { return }
        workbenchStore.presentEditorialDesk(draftRelativePath: draftRelativePath)
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

    var editorialDeskPresentation: EditorialDeskPresentation? {
        get { workbenchStore.editorialDeskPresentation }
        set { workbenchStore.editorialDeskPresentation = newValue }
    }

    func dismissEditorialDesk() {
        workbenchStore.dismissEditorialDesk()
    }

    public func toggleLeftSidebar() {
        workbenchStore.toggleLeftSidebar()
    }

    /// Projects only events accepted by the runtime owner. `/task` is an app
    /// command rather than a backend session, so the facade is its adapter and
    /// must still pass through the same stale-TurnID gate as native and Codex.
    @discardableResult
    private func projectRuntimeEvent(_ event: AgentRuntimeEvent) async -> Bool {
        await agentRuntime.apply(event)
    }

    private func activityReceiptBlock(for receiptID: String) -> ChatBlock? {
        blocks.first { block in
            block.id == receiptID
                || block.workspaceListing?.toolCallID == receiptID
                || block.gitCommit?.hash == receiptID
        }
    }

}
