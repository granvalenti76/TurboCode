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
    // MARK: - Onboarding

    /// Ensures the current `~/.turbocode/` layout exists and applies additive migrations.
    public func ensureOnboarding() async {
        do {
            try TurboCodeConfig.shared.performOnboarding()
            modelRuntimeStore.applyOnboarding(
                tuning: try TurboCodeConfig.shared.loadAgentTuning()
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
        let workspace = WorkspaceStore(gitService: gitService)
        let workbench = WorkbenchStore()
        self.conversationStore = ConversationStore(repository: conversationRepository)
        self.workspaceStore = workspace
        self.toolInteractionStore = toolInteractions
        self.agentActivityStore = agentActivity
        self.timelineStore = timeline
        self.workbenchStore = workbench
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
            Task { await selectCodexProfile() }
            return
        }
        if activeBackend == .codex {
            beginCodexHandoff(to: .backend(backend))
            return
        }
        guard modelRuntimeStore.selectBackend(backend) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    public func switchRemoteModel(to id: String) {
        guard !busy, orchestratorMode == .standalone else { return }
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
    func selectCodexProfile(modelID: String? = nil) async {
        guard !busy, orchestratorMode == .standalone else { return }
        let isEnteringFromTurboCode = activeBackend != .codex
        if isEnteringFromTurboCode, let turboThreadID = activeThreadId {
            codexRuntimeStore.captureImportedContext(
                turboThreadID: turboThreadID,
                blocks: blocks
            )
        }
        modelRuntimeStore.selectCodex(displayName: codexDisplayName)
        error = nil

        do {
            try await codexRuntimeStore.select(modelID: modelID)
            composerModel = "Codex · \(codexDisplayName)"
        } catch CodexAppServerError.chatGPTLoginRequired {
            codexRuntimeStore.markSignedOut()
        } catch let codexError as CodexAppServerError
            where codexError.requiresChatGPTLogin {
            codexRuntimeStore.markSignedOut()
            self.error = nil
        } catch {
            codexRuntimeStore.markFailed(error.localizedDescription)
            self.error = error.localizedDescription
        }
    }

    /// Rechecks the App Server and Luna catalog without changing the selected
    /// profile. This is used by the visible Retry action after runtime errors.
    func retryCodexConnection() {
        guard activeBackend == .codex else { return }
        Task { await selectCodexProfile() }
    }

    /// Starts ChatGPT OAuth through App Server, opens the system default
    /// browser, and automatically finishes setup when the callback arrives.
    func signInToCodex() {
        guard activeBackend == .codex else { return }
        Task {
            error = nil
            do {
                try await codexRuntimeStore.signIn()
                composerModel = "Codex · \(codexDisplayName)"
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
        if activeBackend == .codex {
            beginCodexHandoff(to: .builtIn(id))
            return
        }
        guard modelRuntimeStore.selectBuiltInProfile(id) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    func selectDynamicProfile(_ id: UUID) {
        guard !busy, orchestratorMode == .standalone else { return }
        if activeBackend == .codex {
            beginCodexHandoff(to: .dynamic(id))
            return
        }
        guard modelRuntimeStore.selectDynamicProfile(id) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    /// Selects the supported coordinator route as one atomic runtime change.
    ///
    /// The historical global "orchestrator" mode is the on-device compatibility
    /// path; production coordinator profiles run in standalone transport mode.
    /// Centralizing this transition keeps that implementation detail out of UI.
    func selectCoordinatorProfile(_ id: UUID) {
        guard !busy,
              let profile = dynamicProfiles.first(where: {
                  $0.id == id && $0.isCoordinatorProfile
              }) else {
            return
        }
        modelRuntimeStore.setOrchestratorMode(.standalone)
        guard modelRuntimeStore.selectDynamicProfile(profile.id) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    /// Leaves delegation while preserving the selected profile's base model.
    /// This makes "Direct Model" a real execution choice rather than a label
    /// that silently leaves `delegate_task` enabled.
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
        guard modelRuntimeStore.selectBuiltInProfile(baseModel) else { return }
        rebuildSession(discardingCapabilityContext: true)
    }

    /// Freezes profile selection while Codex prepares any required compact
    /// context. The destination session is installed only after the handoff is
    /// ready, preventing a half-switched UI/runtime state.
    private func beginCodexHandoff(to selection: TurboCodeProfileSelection) {
        guard !busy, activeBackend == .codex else { return }
        busy = true
        Task {
            await completeCodexHandoff(to: selection)
            busy = false
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

        let handoff = await codexRuntimeStore.prepareHandoff(
            turboThreadID: turboThreadID,
            blocks: blocks,
            workspaceRoot: workspaceRoot
        )

        guard applyTurboCodeSelection(selection) else { return }
        if handoff.didSummarize {
            blocks.append(
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
            events: ModelSessionEvents(
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
        if id != activeThreadId { dismissWorkspaceListingInspector() }
        activeThreadId = id
    }

    /// Opens a conversation as one navigation transition. Restoring first keeps
    /// SwiftUI from building the previous, potentially large timeline merely to
    /// replace it one run-loop later when leaving a utility destination.
    public func openThread(_ id: String) async {
        if blocks.isEmpty || activeThreadId != id {
            await restoreSession(id: id)
        } else {
            await selectThread(id)
        }
        setRoute(.chat)
    }

    public func createThread(title: String = "New Chat", mode: ConversationMode = .agent) async {
        dismissWorkspaceListingInspector()
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
        guard let thread = threads.first(where: { $0.id == threadId }) else { return }
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

    /// Loads all session files and populates the thread list.
    public func restoreSessions() async {
        try? conversationStore.restoreCatalog()
    }

    /// Fully restores a past session with its blocks.
    public func restoreSession(id: String) async {
        guard let snapshot = try? conversationStore.snapshot(id: id),
              let _ = threads.firstIndex(where: { $0.id == id }) else { return }
        dismissWorkspaceListingInspector()
        activeThreadId = id
        timelineStore.restore(snapshot.blocks)
        resetAgentActivityForConversation()
        if let wp = snapshot.conversation.workspace, workspaceRoot != wp {
            workspaceRoot = wp
        }
        restoreModelSelection(snapshot.modelBackend)
        let restoredHistory = snapshot.transcript.map {
            SessionRebuildHistory.prepare(
                $0,
                keepingHistory: true,
                discardingCapabilityContext: false
            )
        } ?? SessionRebuildHistory.fromVisibleBlocks(snapshot.blocks)
        rebuildSession(keepingHistory: false, restoringHistory: restoredHistory)
    }

    private func restoreModelSelection(_ identifier: String) {
        guard orchestratorMode == .standalone else { return }
        if identifier.hasPrefix("profile:"),
           let id = UUID(uuidString: String(identifier.dropFirst("profile:".count))),
           dynamicProfiles.contains(where: { $0.id == id }) {
            _ = modelRuntimeStore.selectDynamicProfile(id)
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
            Task { await selectCodexProfile() }
            return
        }
        if identifier == ModelBackend.foundationApple.rawValue {
            _ = modelRuntimeStore.selectBuiltInProfile(.onDevice)
            composerModel = ModelBackend.foundationApple.rawValue
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
    }

    public func pinThread(id: String, pinned: Bool) async {
        conversationStore.pinThread(id: id, pinned: pinned)
    }

    public func archiveThread(id: String) async {
        conversationStore.archiveThread(id: id)
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

        activeThreadId = nil
        timelineStore.reset()
        resetAgentActivityForConversation()

        if let nextThreadID {
            await restoreSession(id: nextThreadID)
            if activeThreadId == nil {
                // A never-persisted draft has no snapshot to restore but remains
                // a valid next selection with a fresh model session.
                activeThreadId = nextThreadID
                rebuildSession(keepingHistory: false)
            }
        } else {
            rebuildSession(keepingHistory: false)
        }
    }

    /// Removes a workspace from TurboCode and deletes only its persisted chats.
    /// The workspace directory and all project files are left untouched.
    public func removeWorkspace(_ path: String) async {
        let conversationRemoval = conversationStore.removeWorkspace(path)
        let removedActiveWorkspace = workspaceStore.removeWorkspace(path)

        if conversationRemoval.removedActiveThread {
            timelineStore.reset()
            resetAgentActivityForConversation()
        }

        if removedActiveWorkspace {
            responseTask?.cancel()
            rightPanelMode = nil
            rebuildSession(keepingHistory: false)
        }

        if !conversationRemoval.deletionErrors.isEmpty {
            let details = conversationRemoval.deletionErrors.joined(separator: "; ")
            error = "Some workspace chats could not be removed: \(details)"
        }
    }

    public func restoreThread(id: String) async {
        conversationStore.restoreThread(id: id)
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
        setWorkspace(url.path)
    }

    /// Switch to a previously opened workspace by path.
    public func switchToWorkspace(_ path: String) {
        setWorkspace(path)
    }

    /// Internal: configure workspace, rebuild session, refresh git state.
    private func setWorkspace(_ path: String) {
        workspaceStore.selectWorkspace(path)

        rebuildSession(discardingCapabilityContext: true)
        // The inspector is opt-in: changing workspace must not open it.
        rightPanelMode = nil
        Task { await reloadDiffs() }
        Task { await refreshGitBranches() }
    }

    /// Clear the workspace selection.
    public func clearWorkspace() {
        workspaceStore.clearWorkspace()
        rebuildSession(discardingCapabilityContext: true)
        rightPanelMode = nil
    }

    public func sendMessage(_ text: String) async {
        let assignment = composerTaskAssignment(for: text)
        guard assignment.allowsOnDevice else {
            // Programmatic sends receive the same fail-closed boundary as the
            // composer. No conversation or model session is started.
            error = assignment.guidance
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

    /// Returns whether the selected profile may receive this composer task.
    /// Only explicit multi-file and architectural signals are rejected; other
    /// profiles and ambiguous prompts preserve the user's chosen route.
    func composerTaskAssignment(
        for text: String
    ) -> OnDeviceTaskAssignment {
        let routing = ModelRoutingPolicy.resolve(
            backend: activeBackend,
            mode: orchestratorMode,
            activeProfile: activeDynamicProfile
        )
        guard routing.role == .microtaskOnDevice else {
            return .eligibleMicrotask
        }
        return OnDeviceCapabilityPolicy.assignment(for: text)
    }

    func isIncompleteSkillCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "/skill"
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
            force: forceRebuild
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

    /// Runs one turn through Codex App Server while preserving TurboCode's
    /// timeline contract. Visual file-change mapping is intentionally a later
    /// adapter layer; this foundation handles text, reasoning and cancellation
    /// without pretending Codex is a FoundationModels provider.
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
            modelName: composerModel
        )
        composerModel = "Codex · \(codexDisplayName)"
        error = result.errorMessage
        if result.touchedConversation {
            conversationStore.touchThread(id: turboThreadID)
        }
        if let titleTask {
            await titleTask.value
        }
        await persistSession(for: turboThreadID)
    }

    private func performSendMessage(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool
    ) async {
        let titleThreadID = activeThreadId
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
        if result.touchedConversation, let activeThreadId {
            conversationStore.touchThread(id: activeThreadId)
        }
        // Persist after the title task finishes so the JSON never races with
        // the Apple on-device title generator and stores a stale "New Chat".
        if let titleTask {
            await titleTask.value
        }
        if let tid = activeThreadId {
            await persistSession(for: tid)
        }
    }

    public func interrupt() {
        responseTask?.cancel()
        let approvals = toolInteractionStore.takeAllApprovals()
        toolInteractionStore.clearActivities()
        Task {
            if activeBackend == .codex {
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
                await sendInternalMessageWhenIdle("""
                [User approved tool action]
                Operation: \(request.operation)
                Path: \(request.path)
                Result:
                \(resolution.result)
                """)
            }
        }
    }

    /// Reject a pending tool operation.
    public func rejectAction() {
        guard let request = toolInteractionStore.takePendingApproval() else { return }
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
                await sendInternalMessageWhenIdle("[User rejected tool action: \(request.summary). Do NOT perform this action.]")
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

    private func sendInternalMessageWhenIdle(_ text: String) async {
        while busy {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
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

    /// Starts the guided coordinator creation flow instead of dropping the user
    /// into an unconfigured generic profile editor.
    func requestCoordinatorProfileCreation() {
        workbenchStore.requestProfileCreation(role: .coordinatorWorker)
    }

    func consumeProfileCreationRequest() -> ProfileExecutionRole? {
        workbenchStore.consumeProfileCreationRequest()
    }

    public func toggleRightPanel(_ mode: RightPanelMode) {
        workbenchStore.toggleRightPanel(mode)
    }

    /// Closes the system inspector without discarding its conversation-local
    /// data, allowing the user to reopen the completed Activity summary.
    func closeRightPanel() {
        workbenchStore.rightPanelMode = nil
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

    private func activityReceiptBlock(for receiptID: String) -> ChatBlock? {
        blocks.first { block in
            block.id == receiptID
                || block.workspaceListing?.toolCallID == receiptID
                || block.gitCommit?.hash == receiptID
        }
    }

}
