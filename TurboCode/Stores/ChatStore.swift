import Foundation
import AppKit
import Observation
import FoundationModels
import FoundationModelsUtilities

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
    // Composer
    public var composerProviderId: String = ""
    public var composerMode: ConversationMode = .agent
    public var composerInput: String = ""
    public var composerAttachments: Int = 0

    // Runtime
    public var runtimeStatus: RuntimeStatus = .ready
    public var runtimeConnection: RuntimeConnectionState = .ready
    public var busy: Bool = false
    public var error: String?
#if DEBUG
    public var benchmarkRunning: Bool = false
    public var benchmarkStatus: String?
#endif

    // Orchestrator mode
    public var orchestratorMode: OrchestratorMode {
        get { modelRuntimeStore.orchestratorMode }
        set {
            modelRuntimeStore.setOrchestratorMode(newValue)
            rebuildSession(discardingCapabilityContext: true)
        }
    }

    // Internal only so the compatibility façade can forward legacy view API.
    let workspaceStore: WorkspaceStore
    let conversationStore: ConversationStore
    let toolInteractionStore: ToolInteractionStore
    let agentActivityStore: AgentActivityStore
    let timelineStore: ChatTimelineStore
    let workbenchStore: WorkbenchStore
    let reviewDraftStore: ReviewDraftStore
    let codexRuntimeStore: CodexRuntimeStore
    let modelRuntimeStore: ModelRuntimeStore
    let responseCoordinator: ChatResponseCoordinator
    private let reviewCoordinator: ReviewCoordinator

    // Session — recreated when backend or workspace changes
    private var session: LanguageModelSession {
        modelRuntimeStore.session
    }
    // The currently running response task. Keeping the handle makes the Stop
    // button cancel the actual model stream rather than only changing the UI.
    private var responseTask: Task<Void, Never>?
    // Codex selection and handoff are also transition operations. Keeping
    // their handles here prevents navigation from observing half-switched
    // backend state while one of them is suspended at an await.
    private var codexSelectionTask: Task<Void, Never>?
    private var codexHandoffTask: Task<Void, Never>?
    // MARK: - Onboarding

    /// Ensures the current `~/.turbocode/` layout exists and applies additive migrations.
    public func ensureOnboarding() async {
        do {
            try TurboCodeConfig.shared.performOnboarding()
            modelRuntimeStore.applyOnboarding(
                tuning: try TurboCodeConfig.shared.loadAgentTuning(),
                workspaceRoot: workspaceRoot
            )
            reloadRemoteModels()
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
        let workspace = WorkspaceStore(
            gitService: gitService,
            reviewDraftStore: reviewDraft
        )
        let workbench = WorkbenchStore()
        self.conversationStore = ConversationStore(repository: conversationRepository)
        self.workspaceStore = workspace
        self.toolInteractionStore = toolInteractions
        self.agentActivityStore = agentActivity
        self.timelineStore = timeline
        self.workbenchStore = workbench
        self.reviewDraftStore = reviewDraft
        self.codexRuntimeStore = codexRuntime
        self.modelRuntimeStore = ModelRuntimeStore()
        self.responseCoordinator = ChatResponseCoordinator(
            timeline: timeline,
            toolInteractions: toolInteractions,
            agentActivity: agentActivity,
            codexRuntime: codexRuntime,
            nativeRunner: nativeRunner
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
    public func switchBackend(to backend: ModelBackend) {
        guard !busy, orchestratorMode == .standalone else { return }
        if backend == .codex {
            scheduleCodexProfileSelection()
            return
        }
        cancelCodexSelection()
        if activeBackend == .codex {
            beginCodexHandoff(to: .backend(backend))
            return
        }
        guard modelRuntimeStore.selectBackend(backend) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    public func switchRemoteModel(to id: String) {
        guard !busy, orchestratorMode == .standalone else { return }
        cancelCodexSelection()
        if activeBackend == .codex {
            beginCodexHandoff(to: .remoteModel(id))
            return
        }
        guard modelRuntimeStore.selectRemoteModel(id: id) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    /// Selects Codex immediately, then verifies ChatGPT authentication and
    /// Luna availability in the background. Connection failure is a runtime
    /// state, not a reason to silently revert the user's menu selection.
    func selectCodexProfile(
        modelID: String? = nil,
        dynamicProfileID: UUID? = nil
    ) async {
        guard !busy, orchestratorMode == .standalone else { return }
        let isEnteringFromTurboCode = activeBackend != .codex
        let routeChanged = activeDynamicProfileID != dynamicProfileID
        if (isEnteringFromTurboCode || routeChanged),
           let turboThreadID = activeThreadId {
            codexRuntimeStore.captureImportedContext(
                turboThreadID: turboThreadID,
                blocks: blocks
            )
            if !isEnteringFromTurboCode {
                // Dynamic tools are fixed when an App Server thread starts.
                // Preserve visible context, then recreate only that hidden
                // runtime boundary for a direct/coordinator route change.
                codexRuntimeStore.resetThread(turboThreadID: turboThreadID)
            }
        }
        modelRuntimeStore.selectCodex(
            displayName: codexDisplayName,
            profileID: dynamicProfileID
        )
        error = nil

        do {
            try await codexRuntimeStore.select(modelID: modelID)
            guard !Task.isCancelled,
                  activeBackend == .codex,
                  activeDynamicProfileID == dynamicProfileID else { return }
            modelRuntimeStore.composerModel = activeDynamicProfile?.name
                ?? "Codex · \(codexDisplayName)"
        } catch is CancellationError {
            return
        } catch CodexAppServerError.chatGPTLoginRequired {
            guard !Task.isCancelled else { return }
            codexRuntimeStore.markSignedOut()
        } catch let codexError as CodexAppServerError
            where codexError.requiresChatGPTLogin {
            guard !Task.isCancelled else { return }
            codexRuntimeStore.markSignedOut()
            self.error = nil
        } catch {
            guard !Task.isCancelled else { return }
            codexRuntimeStore.markFailed(error.localizedDescription)
            self.error = error.localizedDescription
        }
    }

    /// Starts a cancellable Codex selection for UI callers. A later model
    /// choice supersedes the previous request instead of allowing an older
    /// App Server lookup to win after its await completes.
    @discardableResult
    func scheduleCodexProfileSelection(
        modelID: String? = nil,
        dynamicProfileID: UUID? = nil
    ) -> Task<Void, Never> {
        codexSelectionTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.selectCodexProfile(
                modelID: modelID,
                dynamicProfileID: dynamicProfileID
            )
        }
        codexSelectionTask = task
        return task
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
        guard activeBackend == .codex else { return }
        let profileID = activeDynamicProfileID
        scheduleCodexProfileSelection(
            modelID: activeDynamicProfile?.codexModelID,
            dynamicProfileID: profileID
        )
    }

    /// Starts ChatGPT OAuth through App Server, opens the system default
    /// browser, and automatically finishes setup when the callback arrives.
    func signInToCodex() {
        guard activeBackend == .codex else { return }
        Task {
            error = nil
            do {
                try await codexRuntimeStore.signIn()
                modelRuntimeStore.composerModel = activeDynamicProfile?.name
                    ?? "Codex · \(codexDisplayName)"
            } catch {
                codexRuntimeStore.markFailed(error.localizedDescription)
                self.error = error.localizedDescription
            }
        }
    }

    func reopenCodexLoginPage() {
        if !codexRuntimeStore.reopenLoginPage() {
            error = "The Codex authorization page could not be opened."
        }
    }

    func selectBuiltInProfile(_ id: ProfileBaseModelID) {
        guard !busy, orchestratorMode == .standalone else { return }
        if id == .codex {
            scheduleCodexProfileSelection()
            return
        }
        cancelCodexSelection()
        if activeBackend == .codex {
            beginCodexHandoff(to: .builtIn(id))
            return
        }
        guard modelRuntimeStore.selectBuiltInProfile(id) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    func selectDynamicProfile(_ id: UUID) {
        guard !busy, orchestratorMode == .standalone else { return }
        if let profile = dynamicProfiles.first(where: { $0.id == id }),
           profile.baseModelID == .codex {
            scheduleCodexProfileSelection(
                modelID: profile.codexModelID,
                dynamicProfileID: profile.id
            )
            return
        }
        cancelCodexSelection()
        if activeBackend == .codex {
            beginCodexHandoff(to: .dynamic(id))
            return
        }
        guard modelRuntimeStore.selectDynamicProfile(id) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    /// Selects a profile with `delegate_task` as one atomic runtime change.
    ///
    /// The historical global "orchestrator" mode is the on-device compatibility
    /// path; production coordinator profiles run in standalone transport mode.
    /// Centralizing this transition keeps that implementation detail out of UI.
    func selectCoordinatorProfile(_ id: UUID) {
        guard !busy,
              let profile = dynamicProfiles.first(where: {
                  $0.id == id && $0.usesDelegation
              }) else {
            return
        }
        modelRuntimeStore.setOrchestratorMode(.standalone)
        if profile.baseModelID == .codex {
            scheduleCodexProfileSelection(
                modelID: profile.codexModelID,
                dynamicProfileID: profile.id
            )
            return
        }
        cancelCodexSelection()
        guard modelRuntimeStore.selectDynamicProfile(profile.id) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    /// Leaves a custom profile and returns to the current built-in model.
    func selectDirectExecution() {
        guard !busy else { return }
        guard orchestratorMode != .standalone
                || activeDynamicProfile != nil else {
            // Codex and ordinary base-model selections are already direct;
            // choosing the checked menu item must not switch their backend.
            return
        }
        let baseModel = activeDynamicProfile?.baseModelID ?? activeBaseModelID
        modelRuntimeStore.setOrchestratorMode(.standalone)
        if baseModel == .codex {
            scheduleCodexProfileSelection()
            return
        }
        cancelCodexSelection()
        guard modelRuntimeStore.selectBuiltInProfile(baseModel) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    /// Freezes profile selection while Codex prepares any required compact
    /// context. The destination session is installed only after the handoff is
    /// ready, preventing a half-switched UI/runtime state.
    private func beginCodexHandoff(to selection: TurboCodeProfileSelection) {
        guard !busy, activeBackend == .codex else { return }
        cancelCodexSelection()
        busy = true
        codexHandoffTask?.cancel()
        codexHandoffTask = Task { [weak self] in
            guard let self else { return }
            await completeCodexHandoff(to: selection)
            self.busy = false
        }
    }

    private func completeCodexHandoff(
        to selection: TurboCodeProfileSelection
    ) async {
        guard let turboThreadID = activeThreadId else {
            _ = applyTurboCodeSelection(selection)
            rebuildSession(discardingCapabilityContext: true)
            return
        }
        let handoffWorkspaceRoot = workspaceRoot

        let handoff = await codexRuntimeStore.prepareHandoff(
            turboThreadID: turboThreadID,
            blocks: blocks,
            workspaceRoot: handoffWorkspaceRoot
        )

        guard !Task.isCancelled,
              activeThreadId == turboThreadID,
              workspaceRoot == handoffWorkspaceRoot else {
            return
        }
        guard applyTurboCodeSelection(selection) else { return }
        if handoff.didSummarize {
            timelineStore.blocks.append(
                ChatBlock(
                    kind: .compaction,
                    text: "Codex context summarized for the selected TurboCode profile."
                )
            )
        }
        codexRuntimeStore.completeHandoff(
            turboThreadID: turboThreadID,
            boundaryBlockID: blocks.last?.id
        )
        rebuildSession(
            keepingHistory: false,
            discardingCapabilityContext: true,
            restoringHistory: handoff.history
        )
    }

    /// Applies a captured menu choice without rebuilding. This is separated
    /// from the public selectors so a Codex handoff can inject one precise
    /// transcript into the newly configured FoundationModels session.
    private func applyTurboCodeSelection(
        _ selection: TurboCodeProfileSelection
    ) -> Bool {
        switch selection {
        case .backend(let backend):
            return modelRuntimeStore.selectBackend(backend)
        case .remoteModel(let id):
            return modelRuntimeStore.selectRemoteModel(id: id)
        case .builtIn(let id):
            return modelRuntimeStore.selectBuiltInProfile(id)
        case .dynamic(let id):
            return modelRuntimeStore.selectDynamicProfile(id)
        }
    }

    func reloadDynamicProfiles(selecting id: UUID? = nil) {
        do {
            if try modelRuntimeStore.reloadDynamicProfiles(selecting: id) {
                rebuildSession(discardingCapabilityContext: true)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func reloadRemoteModels() {
        guard modelRuntimeStore.reloadRemoteModels() else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    public func isConfigured(_ model: RemoteModelConfig) -> Bool {
        modelRuntimeStore.isConfigured(model)
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        modelRuntimeStore.setReasoningEffort(effort)
        rebuildSession()
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
        restoringHistory: [Transcript.Entry]? = nil
    ) {
        modelRuntimeStore.rebuildSession(
            workspaceRoot: workspaceRoot,
            keepingHistory: keepingHistory,
            discardingCapabilityContext: discardingCapabilityContext,
            restoringHistory: restoringHistory,
            events: modelSessionEvents
        )
    }

    /// Shares native tool and Activity presentation with every coordinator
    /// transport, including Codex's dynamically advertised delegation tool.
    private var modelSessionEvents: ModelSessionEvents {
        ModelSessionEvents(
            toolStarted: { [weak self] call, backend, owner in
                await self?.responseCoordinator.toolStarted(
                    call,
                    backend: backend,
                    owner: owner
                )
            },
            toolFinished: { [weak self] call, output, backend, owner in
                guard let self else { return }
                await self.responseCoordinator.toolFinished(
                    call,
                    output: output,
                    backend: backend,
                    owner: owner,
                    workspaceName: self.workspaceRoot.isEmpty
                        ? nil
                        : self.workspaceLabel
                )
            },
            delegationChanged: { [weak self] isDelegating in
                await MainActor.run {
                    self?.responseCoordinator.delegationChanged(isDelegating)
                }
            },
            agentActivityChanged: { [weak self] event in
                guard let self else { return }
                await self.handleAgentActivityEvent(event)
            }
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
        conversationStore.createThread(
            title: title,
            workspace: workspaceRoot.isEmpty ? nil : workspaceRoot,
            mode: mode
        )
        timelineStore.reset()
        resetAgentActivityForConversation()
        rebuildSession(keepingHistory: false)
    }

    /// Makes every message entry point safe to use without requiring the user
    /// to press New Chat first. If an older buggy flow already produced blocks
    /// without a thread, attach them to the new metadata instead of discarding
    /// the visible conversation.
    private func ensureActiveThread() {
        let hasOrphanedBlocks = !blocks.isEmpty
        let created = conversationStore.ensureActiveThread(
            workspace: workspaceRoot.isEmpty ? nil : workspaceRoot,
            mode: composerMode
        )
        guard created, !hasOrphanedBlocks else { return }

        timelineStore.reset()
        resetAgentActivityForConversation()
        rebuildSession(keepingHistory: false)
    }

    /// Generates a concise title from the first user prompt using the Apple
    /// on-device model, then applies it to the thread that initiated the request.
    public func generateTitle(from prompt: String, for threadID: String? = nil) async {
        // Capture identity before inference: the active conversation can change
        // while the on-device model streams a title in the background.
        guard let threadID = threadID ?? activeThreadId,
              threads.contains(where: { $0.id == threadID && $0.title == "New Chat" }) else { return }

        let titlePrompt = """
        Generate a very short title (max 6 words) for a conversation that starts with this message.
        Respond with ONLY the title, no quotes, no punctuation.

        Message: \(prompt)
        """

        do {
            let model = SystemLanguageModel.default
            let titleSession = LanguageModelSession(model: model)
            var generated = ""
            for try await snapshot in titleSession.streamResponse(to: titlePrompt) {
                if !snapshot.content.isEmpty {
                    generated = snapshot.content
                }
            }
            let clean = generated
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            if !clean.isEmpty {
                applyGeneratedTitle(String(clean.prefix(60)), to: threadID)
            }
        } catch {
            // Silently fall back to "New Chat"
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
        guard threadId == activeThreadId,
              let thread = threads.first(where: { $0.id == threadId }) else {
            assertionFailure("persistSession can only persist the active thread")
            return
        }
        let snapshot = ConversationSnapshot(
            conversation: thread,
            modelBackend: modelRuntimeStore.persistedModelIdentifier,
            blocks: blocks,
            // Codex persists its own rollout. Saving an unrelated Foundation
            // Models transcript here would contaminate later restoration.
            transcript: activeBackend == .codex ? nil : session.transcript
        )
        do {
            try conversationStore.persist(snapshot)
        } catch {
            print("[TurboCode] Failed to persist session: \(error.localizedDescription)")
        }
    }

    /// Persists catalog-only changes without replacing a non-active thread's
    /// timeline. Active drafts use the full session snapshot; older threads
    /// retain their durable blocks and transcript while only metadata changes.
    private func persistConversationMetadata(for threadID: String) async {
        if threadID == activeThreadId {
            await persistSession(for: threadID)
            return
        }
        do {
            try conversationStore.persistMetadata(id: threadID)
        } catch {
            print("[TurboCode] Failed to persist conversation metadata: \(error.localizedDescription)")
        }
    }

    /// Loads all session files and populates the thread list.
    public func restoreSessions() async {
        try? conversationStore.restoreCatalog()
    }

    /// Fully restores a past session with its blocks.
    public func restoreSession(id: String) async {
        await finishActiveResponseBeforeTransition()
        guard let snapshot = try? conversationStore.snapshot(id: id),
              let _ = threads.firstIndex(where: { $0.id == id }) else { return }
        dismissWorkspaceListingInspector()
        workbenchStore.dismissDiffPatchReview()
        reviewDraftStore.discardAll()
        conversationStore.activeThreadID = id
        timelineStore.restore(snapshot.blocks)
        resetAgentActivityForConversation()
        if let wp = snapshot.conversation.workspace, workspaceRoot != wp {
            // Restoration adopts the persisted root without starting the
            // interactive workspace transition a second time.
            workspaceStore.root = wp
        }
        refreshSkillsIfNeeded()
        await restoreModelSelection(snapshot.modelBackend)
        let restoredHistory = snapshot.transcript.map {
            SessionRebuildHistory.prepare(
                $0,
                keepingHistory: true,
                discardingCapabilityContext: false
            )
        } ?? SessionRebuildHistory.fromVisibleBlocks(snapshot.blocks)
        rebuildSession(keepingHistory: false, restoringHistory: restoredHistory)
    }

    private func restoreModelSelection(_ identifier: String) async {
        guard orchestratorMode == .standalone else { return }
        if identifier.hasPrefix("profile:"),
           let id = UUID(uuidString: String(identifier.dropFirst("profile:".count))),
           let profile = dynamicProfiles.first(where: { $0.id == id }) {
            if profile.baseModelID == .codex {
                if let turboThreadID = activeThreadId {
                    codexRuntimeStore.restoreImportedContext(
                        turboThreadID: turboThreadID,
                        blocks: blocks
                    )
                }
                let task = scheduleCodexProfileSelection(
                    modelID: profile.codexModelID,
                    dynamicProfileID: profile.id
                )
                await task.value
            } else {
                cancelCodexSelection()
                _ = modelRuntimeStore.selectDynamicProfile(id)
            }
            return
        }
        if identifier == ModelBackend.codex.rawValue {
            modelRuntimeStore.selectCodex(displayName: codexDisplayName)
            if let turboThreadID = activeThreadId {
                codexRuntimeStore.restoreImportedContext(
                    turboThreadID: turboThreadID,
                    blocks: blocks
                )
            }
            let task = scheduleCodexProfileSelection()
            await task.value
            return
        }
        cancelCodexSelection()
        if identifier == ModelBackend.foundationApple.rawValue {
            _ = modelRuntimeStore.selectBuiltInProfile(.onDevice)
            modelRuntimeStore.composerModel = ModelBackend.foundationApple.rawValue
            return
        }

        let legacyRole: RemoteModelRole? = switch identifier {
        case ModelBackend.llamaServer.rawValue: .local
        case ModelBackend.foundationServe.rawValue: .pcc
        default: nil
        }
        let model = remoteModels.first(where: {
            $0.enabled && ($0.id == identifier || $0.role == legacyRole)
        })
        if let model, isConfigured(model) {
            _ = modelRuntimeStore.selectRemoteModel(id: model.id)
        }
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
        if deletesActiveThread, let responseTask {
            // A cancelled response still performs its final persistence pass.
            // Wait for that pass before deleting, otherwise it can recreate the
            // session file immediately after the user removes the conversation.
            responseTask.cancel()
            await responseTask.value
        }

        let nextThreadID: String?
        do {
            nextThreadID = try conversationStore.deleteThread(id: id)
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
        timelineStore.reset()
        resetAgentActivityForConversation()
        reviewDraftStore.discardAll()

        if let nextThreadID {
            await restoreSession(id: nextThreadID)
            if activeThreadId == nil {
                // A never-persisted draft has no snapshot to restore but remains
                // a valid next selection with a fresh model session.
                conversationStore.activeThreadID = nextThreadID
                rebuildSession(keepingHistory: false)
            }
        } else {
            rebuildSession(keepingHistory: false)
        }
    }

    /// Removes a workspace from TurboCode and deletes only its persisted chats.
    /// The workspace directory and all project files are left untouched.
    public func removeWorkspace(_ path: String) async {
        await finishActiveResponseBeforeTransition()
        let conversationRemoval = conversationStore.removeWorkspace(path)
        let removedActiveWorkspace = workspaceStore.removeWorkspace(path)

        if conversationRemoval.removedActiveThread {
            timelineStore.reset()
            resetAgentActivityForConversation()
        }

        if removedActiveWorkspace {
            workbenchStore.rightPanelMode = nil
            rebuildSession(keepingHistory: false)
        }

        if !conversationRemoval.deletionErrors.isEmpty {
            let details = conversationRemoval.deletionErrors.joined(separator: "; ")
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

        refreshSkillsIfNeeded()
        rebuildSession(discardingCapabilityContext: true)
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
            rebuildSession(discardingCapabilityContext: true)
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
        if let taskGoal = Self.taskCommandGoal(from: text) {
            await runIndependentTask(taskGoal)
            return
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "/task" {
            error = "Use /task followed by the task instructions."
            return
        }
        refreshSkillsIfNeeded()
        if activeBackend != .codex,
           modelRuntimeStore.workspaceInstructionsChanged(in: workspaceRoot) {
            // LanguageModelSession instructions are immutable. Preserve visible
            // history while replacing only the stale system-instruction prefix.
            rebuildSession()
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

        refreshSkillsIfNeeded()
        if activeBackend != .codex,
           modelRuntimeStore.workspaceInstructionsChanged(in: workspaceRoot) {
            rebuildSession()
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
            ensureActiveThread()
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
            || Self.taskCommandGoal(from: trimmed) != nil
    }

    /// Runs `/task <instructions>` through the configured worker directly.
    /// The active profile does not need to advertise `delegate_task`, because
    /// this is an explicit application command rather than model tool use.
    private func runIndependentTask(_ goal: String) async {
        guard !busy else { return }
        let command = "/task \(goal)"
        let envelope: AgentTaskEnvelope
        do {
            envelope = try DelegateTaskArguments(
                mode: DelegatedWorkerMode.coding.rawValue,
                goal: goal
            ).envelope()
        } catch {
            self.error = error.localizedDescription
            return
        }

        ensureActiveThread()
        let invoker = modelRuntimeStore.makeIndependentTaskInvoker(
            workspaceRoot: workspaceRoot,
            events: modelSessionEvents
        )
        error = nil
        responseCoordinator.delegationChanged(true)
        busy = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            let result = await invoker.invoke(envelope)
            await self.finishIndependentTask(
                command: command,
                result: result
            )
        }
        responseTask = task
        await task.value
        responseTask = nil
        busy = false
        responseCoordinator.delegationChanged(false)
    }

    /// Publishes the worker's typed terminal result as a visible assistant
    /// turn and refreshes the current model transcript with that outcome.
    private func finishIndependentTask(
        command: String,
        result: AgentTaskResult
    ) async {
        let response = Self.renderIndependentTaskResult(result)
        timelineStore.presentTaskTurn(command: command, response: response)
        appendIndependentTaskToTranscript(command: command, response: response)
        if let threadID = activeThreadId {
            conversationStore.touchThread(id: threadID)
            if activeBackend == .codex {
                codexRuntimeStore.captureImportedContext(
                    turboThreadID: threadID,
                    blocks: blocks
                )
            }
            await persistSession(for: threadID)
        }
    }

    /// Keeps the worker answer available to the next Foundation Models turn
    /// without copying its internal tool-call transcript into the coordinator.
    private func appendIndependentTaskToTranscript(
        command: String,
        response: String
    ) {
        guard activeBackend != .codex else { return }
        let additions = RuntimeContextHandoff.transcript(from: [
            ChatBlock(kind: .user, text: command),
            ChatBlock(kind: .assistant, text: response)
        ])
        let existing = SessionRebuildHistory.prepare(
            session.transcript,
            keepingHistory: true,
            discardingCapabilityContext: false
        )
        rebuildSession(restoringHistory: existing + additions)
    }

    private static func renderIndependentTaskResult(
        _ result: AgentTaskResult
    ) -> String {
        var sections = [
            "### Independent task",
            result.technicalSummary
        ]
        if let failureDetail = result.failureDetail,
           !failureDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("**Details:** \(failureDetail)")
        }
        if !result.unresolvedWork.isEmpty {
            sections.append(
                "**Remaining:**\n" + result.unresolvedWork
                    .map { "- \($0)" }
                    .joined(separator: "\n")
            )
        }
        if result.outcome == .failed || result.outcome == .cancelled {
            sections.insert(
                "Status: `\(result.outcome.rawValue)`",
                at: 1
            )
        }
        return sections.joined(separator: "\n\n")
    }

    private static func taskCommandGoal(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/task ") else { return nil }
        let goal = String(trimmed.dropFirst("/task ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? nil : goal
    }

    public func reloadSkills() {
        refreshSkillsIfNeeded(forceRebuild: true)
    }

    func applyAgentTuning(_ value: AgentTuningConfig) {
        guard modelRuntimeStore.applyAgentTuning(value) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    private func refreshSkillsIfNeeded(forceRebuild: Bool = false) {
        guard modelRuntimeStore.refreshSkills(
            force: forceRebuild,
            workspaceRoot: workspaceRoot
        ) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    private func sendMessage(
        _ text: String,
        promptText: String? = nil,
        visibleInTimeline: Bool
    ) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !busy,
              activeProfileCanSend else { return }

        compactOnDeviceContextIfNeeded()
        let effectivePrompt = promptText ?? text
        ensureActiveThread()
        busy = true
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            if self.activeBackend == .codex {
                await self.performCodexSendMessage(
                    displayText: text,
                    promptText: effectivePrompt,
                    visibleInTimeline: visibleInTimeline
                )
            } else {
                await self.performSendMessage(
                    displayText: text,
                    promptText: effectivePrompt,
                    visibleInTimeline: visibleInTimeline
                )
            }
        }
        responseTask = task
        await task.value
        responseTask = nil
        busy = false
    }

    /// Compacts only at a turn boundary, when the previous on-device context
    /// has reached eight question/answer turns. The active session is rebuilt
    /// from a concise handoff so the ninth question starts with usable context.
    private func compactOnDeviceContextIfNeeded() {
        guard activeBackend == .foundationApple else { return }
        let turnCount = SessionRebuildHistory.userTurnCount(in: session.transcript)
        guard turnCount >= SessionRebuildHistory.onDeviceCompactionThreshold,
              let compaction = SessionRebuildHistory.onDeviceCompaction(from: blocks)
        else { return }

        timelineStore.presentCompaction(compaction.summary)
        rebuildSession(restoringHistory: compaction.history)
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
        visibleInTimeline: Bool
    ) async {
        let titleThreadID = activeThreadId
        let titleTask: Task<Void, Never>? = visibleInTimeline ? Task { [weak self] in
            guard let self else { return }
            await self.generateTitle(from: displayText, for: titleThreadID)
        } : nil

        error = nil
        guard let turboThreadID = activeThreadId else {
            self.error = "TurboCode could not create the conversation."
            return
        }
        let result = await responseCoordinator.performCodex(
            displayText: displayText,
            promptText: promptText,
            visibleInTimeline: visibleInTimeline,
            turboThreadID: turboThreadID,
            workspaceRoot: workspaceRoot,
            workspaceName: workspaceRoot.isEmpty ? nil : workspaceLabel,
            agentTuning: agentTuning,
            availableSkills: DynamicProfileRuntimeSelection.skills(
                from: modelRuntimeStore.availableSkills,
                profile: activeDynamicProfile
            ),
            codexModelID: activeDynamicProfile?.codexModelID,
            codexReasoningEffort:
                activeDynamicProfile?.codexReasoningEffort,
            delegationInvoker: modelRuntimeStore.makeDelegateInvoker(
                workspaceRoot: workspaceRoot,
                events: modelSessionEvents
            ),
            modelName: composerModel
        )
        modelRuntimeStore.composerModel = activeDynamicProfile?.name
            ?? "Codex · \(codexDisplayName)"
        error = result.errorMessage
        if result.touchedConversation {
            conversationStore.touchThread(id: turboThreadID)
        }
        if let titleTask {
            await titleTask.value
        }
        // A skill created by skill-creator becomes available to the next turn
        // without requiring an app restart or a manual Skills reload.
        refreshSkillsIfNeeded()
        await persistSession(for: turboThreadID)
    }

    private func performSendMessage(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool
    ) async {
        let conversationID = activeThreadId
        let titleThreadID = conversationID
        let titleTask: Task<Void, Never>? = visibleInTimeline ? Task { [weak self] in
            guard let self else { return }
            await self.generateTitle(from: displayText, for: titleThreadID)
        } : nil
        runtimeStatus = .ready
        error = nil
        let result = await responseCoordinator.performNative(
            displayText: displayText,
            promptText: promptText,
            visibleInTimeline: visibleInTimeline,
            blocks: blocks,
            session: session,
            backend: activeBackend,
            mode: orchestratorMode,
            workspaceKind: diagnosticsWorkspaceKind,
            modelName: composerModel
        )
        error = result.errorMessage
        if result.touchedConversation, let conversationID {
            conversationStore.touchThread(id: conversationID)
        }
        // Persist after the title task finishes so the JSON never races with
        // the Apple on-device title generator and stores a stale "New Chat".
        if let titleTask {
            await titleTask.value
        }
        // A skill created by skill-creator becomes available to the next turn
        // without requiring an app restart or a manual Skills reload.
        refreshSkillsIfNeeded()
        if let conversationID, activeThreadId == conversationID {
            await persistSession(for: conversationID)
        }
    }

    public func interrupt() {
        responseTask?.cancel()
        let shouldInterruptCodex = activeBackend == .codex
        let approvals = toolInteractionStore.takeAllApprovals()
        toolInteractionStore.clearActivities()
        Task {
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
    }

#if DEBUG
    public func runActiveEditingBenchmark() async {
        guard !benchmarkRunning, !busy else { return }
        benchmarkRunning = true
        benchmarkStatus = "Running \(activeBackend.rawValue) editing benchmark..."
        defer { benchmarkRunning = false }

        let model: any LanguageModel
        switch activeBackend {
        case .foundationApple:
            model = SystemLanguageModel.default
        case .foundationServe, .llamaServer, .premium:
            model = modelRuntimeStore.languageModel(
                for: activeRemoteModel ?? RemoteModelConfig.fallbackLlama
            )
        case .codex:
            benchmarkStatus = "Codex uses its own App Server evaluation path."
            return
        }
        let result = await AgentBenchmarkRunner.runSuite(
            backend: activeBackend,
            model: model,
            reasoningLevel: reasoningLevel
        )
        benchmarkStatus = result.summary
        print("[Benchmark] \(result.summary)")
    }

    public func printToolFailureSummary() async {
        let summary = await AgentDiagnosticsRecorder.shared.failureSummary()
        print("[Diagnostics] \(summary)")
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
        while busy {
            guard !Task.isCancelled else { return }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }
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
        workbenchStore.toggleRightPanel(mode)
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

    private func cancelCodexSelection() {
        codexSelectionTask?.cancel()
        codexSelectionTask = nil
    }

    /// Navigation and workspace changes are transaction boundaries for a live
    /// response. Waiting for the cancelled task to finish lets its final
    /// persistence pass target the old conversation before the new timeline or
    /// workspace is installed.
    private func finishActiveResponseBeforeTransition() async {
        if let selectionTask = codexSelectionTask {
            selectionTask.cancel()
            await selectionTask.value
            codexSelectionTask = nil
        }
        if let responseTask {
            responseTask.cancel()
            await responseTask.value
            if self.responseTask != nil {
                self.responseTask = nil
                busy = false
            }
        }
        if let handoffTask = codexHandoffTask {
            handoffTask.cancel()
            await handoffTask.value
            codexHandoffTask = nil
            busy = false
        }
    }

    private func activityReceiptBlock(for receiptID: String) -> ChatBlock? {
        blocks.first { block in
            block.id == receiptID
                || block.workspaceListing?.toolCallID == receiptID
                || block.gitCommit?.hash == receiptID
        }
    }

}
