import Foundation

/// Owns model/profile selection, Codex connection transitions, and session
/// rebuilds. Keeping cancellable selection and handoff tasks here prevents the
/// UI facade from becoming the lifetime owner of provider routing work.
@MainActor
final class ProfileSelectionCoordinator {
    private let modelRuntime: ModelRuntimeStore
    private let codexRuntime: CodexRuntimeStore
    private let conversations: ConversationStore
    private let timeline: ChatTimelineStore
    private let workspace: WorkspaceStore
    private let presentation: ChatPresentationViewModel
    private let agentRuntime: AgentRuntime
    private let llmRuntime: LLMRuntime
    private let runtimeProjection: AgentRuntimeProjectionStore
    private let responseCoordinator: ChatResponseCoordinator

    private var codexSelectionTask: Task<Void, Never>?
    private var codexHandoffTask: Task<Void, Never>?
    private var codexHandoffID: UUID?

    var isTransitioning: Bool { codexHandoffTask != nil }

    init(
        modelRuntime: ModelRuntimeStore,
        codexRuntime: CodexRuntimeStore,
        conversations: ConversationStore,
        timeline: ChatTimelineStore,
        workspace: WorkspaceStore,
        presentation: ChatPresentationViewModel,
        agentRuntime: AgentRuntime,
        llmRuntime: LLMRuntime,
        runtimeProjection: AgentRuntimeProjectionStore,
        responseCoordinator: ChatResponseCoordinator
    ) {
        self.modelRuntime = modelRuntime
        self.codexRuntime = codexRuntime
        self.conversations = conversations
        self.timeline = timeline
        self.workspace = workspace
        self.presentation = presentation
        self.agentRuntime = agentRuntime
        self.llmRuntime = llmRuntime
        self.runtimeProjection = runtimeProjection
        self.responseCoordinator = responseCoordinator
    }

    func setOrchestratorMode(_ mode: OrchestratorMode) async {
        modelRuntime.setOrchestratorMode(mode)
        await rebuildSession(discardingCapabilityContext: true)
    }

    func switchBackend(to backend: ModelBackend) async {
        guard !isBusy, modelRuntime.orchestratorMode == .standalone else { return }
        if backend == .codex {
            scheduleCodexProfileSelection()
            return
        }
        cancelCodexSelection()
        if modelRuntime.activeBackend == .codex {
            beginCodexHandoff(to: .backend(backend))
            return
        }
        guard modelRuntime.selectBackend(backend) else { return }
        await rebuildSession(discardingCapabilityContext: true)
    }

    func switchRemoteModel(to id: String) async {
        guard !isBusy, modelRuntime.orchestratorMode == .standalone else { return }
        cancelCodexSelection()
        if modelRuntime.activeBackend == .codex {
            beginCodexHandoff(to: .remoteModel(id))
            return
        }
        guard modelRuntime.selectRemoteModel(id: id) else { return }
        await rebuildSession(discardingCapabilityContext: true)
    }

    func selectCodexProfile(
        modelID: String? = nil,
        dynamicProfileID: UUID? = nil
    ) async {
        guard !isBusy, modelRuntime.orchestratorMode == .standalone else { return }
        let isEnteringFromTurboCode = modelRuntime.activeBackend != .codex
        let routeChanged = modelRuntime.activeDynamicProfileID != dynamicProfileID
        if (isEnteringFromTurboCode || routeChanged),
           let threadID = conversations.activeThreadID {
            await codexRuntime.captureImportedContext(
                turboThreadID: threadID,
                blocks: timeline.blocks
            )
            if !isEnteringFromTurboCode {
                // Dynamic tools are fixed when an App Server thread starts.
                // Recreate only that hidden boundary for a route change.
                await codexRuntime.resetThread(turboThreadID: threadID)
            }
        }
        modelRuntime.selectCodex(
            displayName: codexRuntime.displayName,
            profileID: dynamicProfileID
        )
        presentation.errorMessage = nil

        do {
            try await codexRuntime.select(modelID: modelID)
            guard !Task.isCancelled,
                  modelRuntime.activeBackend == .codex,
                  modelRuntime.activeDynamicProfileID == dynamicProfileID else { return }
            modelRuntime.composerModel = modelRuntime.activeDynamicProfile?.name
                ?? "Codex · \(codexRuntime.displayName)"
        } catch is CancellationError {
            return
        } catch CodexAppServerError.chatGPTLoginRequired {
            guard !Task.isCancelled else { return }
            codexRuntime.markSignedOut()
        } catch let codexError as CodexAppServerError
            where codexError.requiresChatGPTLogin {
            guard !Task.isCancelled else { return }
            codexRuntime.markSignedOut()
            presentation.errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            codexRuntime.markFailed(error.localizedDescription)
            presentation.errorMessage = error.localizedDescription
        }
    }

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

    func retryCodexConnection() {
        guard modelRuntime.activeBackend == .codex else { return }
        scheduleCodexProfileSelection(
            modelID: modelRuntime.activeDynamicProfile?.codexModelID,
            dynamicProfileID: modelRuntime.activeDynamicProfileID
        )
    }

    func signInToCodex() {
        guard modelRuntime.activeBackend == .codex else { return }
        Task { [weak self] in
            guard let self else { return }
            presentation.errorMessage = nil
            do {
                try await codexRuntime.signIn()
                modelRuntime.composerModel = modelRuntime.activeDynamicProfile?.name
                    ?? "Codex · \(codexRuntime.displayName)"
            } catch {
                codexRuntime.markFailed(error.localizedDescription)
                presentation.errorMessage = error.localizedDescription
            }
        }
    }

    func reopenCodexLoginPage() {
        if !codexRuntime.reopenLoginPage() {
            presentation.errorMessage = "The Codex authorization page could not be opened."
        }
    }

    func selectBuiltInProfile(_ id: ProfileBaseModelID) async {
        guard !isBusy, modelRuntime.orchestratorMode == .standalone else { return }
        if id == .codex {
            scheduleCodexProfileSelection()
            return
        }
        cancelCodexSelection()
        if modelRuntime.activeBackend == .codex {
            beginCodexHandoff(to: .builtIn(id))
            return
        }
        guard modelRuntime.selectBuiltInProfile(id) else { return }
        await rebuildSession(discardingCapabilityContext: true)
    }

    func selectDynamicProfile(_ id: UUID) async {
        guard !isBusy, modelRuntime.orchestratorMode == .standalone else { return }
        if let profile = modelRuntime.dynamicProfiles.first(where: { $0.id == id }),
           profile.baseModelID == .codex {
            scheduleCodexProfileSelection(
                modelID: profile.codexModelID,
                dynamicProfileID: profile.id
            )
            return
        }
        cancelCodexSelection()
        if modelRuntime.activeBackend == .codex {
            beginCodexHandoff(to: .dynamic(id))
            return
        }
        guard modelRuntime.selectDynamicProfile(id) else { return }
        await rebuildSession(discardingCapabilityContext: true)
    }

    func selectCoordinatorProfile(_ id: UUID) async {
        guard !isBusy,
              let profile = modelRuntime.dynamicProfiles.first(where: {
                  $0.id == id && $0.usesDelegation
              }) else { return }
        modelRuntime.setOrchestratorMode(.standalone)
        if profile.baseModelID == .codex {
            scheduleCodexProfileSelection(
                modelID: profile.codexModelID,
                dynamicProfileID: profile.id
            )
            return
        }
        cancelCodexSelection()
        guard modelRuntime.selectDynamicProfile(profile.id) else { return }
        await rebuildSession(discardingCapabilityContext: true)
    }

    func selectDirectExecution() async {
        guard !isBusy else { return }
        guard modelRuntime.orchestratorMode != .standalone
                || modelRuntime.activeDynamicProfile != nil else { return }
        let baseModel = modelRuntime.activeDynamicProfile?.baseModelID
            ?? modelRuntime.activeBaseModelID
        modelRuntime.setOrchestratorMode(.standalone)
        if baseModel == .codex {
            scheduleCodexProfileSelection()
            return
        }
        cancelCodexSelection()
        guard modelRuntime.selectBuiltInProfile(baseModel) else { return }
        await rebuildSession(discardingCapabilityContext: true)
    }

    func reloadDynamicProfiles(selecting id: UUID? = nil) async {
        do {
            if try modelRuntime.reloadDynamicProfiles(selecting: id) {
                await rebuildSession(discardingCapabilityContext: true)
            }
        } catch {
            presentation.errorMessage = error.localizedDescription
        }
    }

    func reloadRemoteModels() async {
        guard modelRuntime.reloadRemoteModels() else { return }
        await rebuildSession(discardingCapabilityContext: true)
    }

    func setReasoningEffort(_ effort: ReasoningEffort) async {
        modelRuntime.setReasoningEffort(effort)
        await rebuildSession()
    }

    /// Refreshes workspace-scoped skill capabilities at the model-selection
    /// boundary. Restore, send, and explicit reload flows all require the same
    /// capability rebuild and must not depend on one another's coordinators.
    func refreshSkillsIfNeeded(forceRebuild: Bool = false) async {
        guard refreshSkills(force: forceRebuild) else { return }
        await rebuildSession(discardingCapabilityContext: true)
    }

    /// Updates the selected capability set without rebuilding. Context-change
    /// coordinators use this before their one mandatory provider rebuild.
    @discardableResult
    func refreshSkills(force: Bool = false) -> Bool {
        modelRuntime.refreshSkills(
            force: force,
            workspaceRoot: workspace.root
        )
    }

    func restoreModelSelection(_ identifier: String) async {
        guard modelRuntime.orchestratorMode == .standalone else { return }
        if identifier.hasPrefix("profile:"),
           let id = UUID(uuidString: String(identifier.dropFirst("profile:".count))),
           let profile = modelRuntime.dynamicProfiles.first(where: { $0.id == id }) {
            if profile.baseModelID == .codex {
                await restoreCodexImportedContext()
                await scheduleCodexProfileSelection(
                    modelID: profile.codexModelID,
                    dynamicProfileID: profile.id
                ).value
            } else {
                cancelCodexSelection()
                _ = modelRuntime.selectDynamicProfile(id)
            }
            return
        }
        if identifier == ModelBackend.codex.rawValue {
            modelRuntime.selectCodex(displayName: codexRuntime.displayName)
            await restoreCodexImportedContext()
            await scheduleCodexProfileSelection().value
            return
        }
        cancelCodexSelection()
        if identifier == ModelBackend.foundationApple.rawValue {
            _ = modelRuntime.selectBuiltInProfile(.onDevice)
            modelRuntime.composerModel = ModelBackend.foundationApple.rawValue
            return
        }

        let legacyRole: RemoteModelRole? = switch identifier {
        case ModelBackend.llamaServer.rawValue: .local
        case ModelBackend.foundationServe.rawValue: .pcc
        default: nil
        }
        if let model = modelRuntime.remoteModels.first(where: {
            $0.enabled && ($0.id == identifier || $0.role == legacyRole)
        }), modelRuntime.isConfigured(model) {
            _ = modelRuntime.selectRemoteModel(id: model.id)
        }
    }

    func rebuildSession(
        keepingHistory: Bool = true,
        discardingCapabilityContext: Bool = false,
        restoringHistory: [FoundationModelsTranscriptEntry]? = nil
    ) async {
        presentation.setLlamaContextUsage(nil)
        _ = await agentRuntime.apply(
            .switchBackend(
                RuntimeBackendSelection(
                    backend: modelRuntime.activeBackend,
                    modelName: modelRuntime.composerModel
                )
            )
        )
        let configuration = modelRuntime.makeSessionConfiguration(
            workspaceRoot: workspace.root
        )
        await llmRuntime.rebuildFoundationModelsSession(
            configuration: configuration,
            keepingHistory: keepingHistory,
            discardingCapabilityContext: discardingCapabilityContext,
            restoringHistory: restoringHistory,
            events: responseCoordinator.modelSessionEvents
        )
    }

    /// Joins profile tasks at navigation boundaries so their delayed callbacks
    /// cannot mutate the model selected for a different conversation.
    func cancelAndWaitForTransitions() async {
        if let selectionTask = codexSelectionTask {
            selectionTask.cancel()
            await selectionTask.value
            codexSelectionTask = nil
        }
        if let handoffTask = codexHandoffTask {
            handoffTask.cancel()
            await handoffTask.value
            codexHandoffTask = nil
            codexHandoffID = nil
            presentation.setProfileTransitioning(false)
        }
    }

    private var isBusy: Bool {
        runtimeProjection.hasActiveOperation || codexHandoffTask != nil
    }

    private func cancelCodexSelection() {
        codexSelectionTask?.cancel()
        codexSelectionTask = nil
    }

    private func beginCodexHandoff(to selection: TurboCodeProfileSelection) {
        guard !isBusy, modelRuntime.activeBackend == .codex else { return }
        cancelCodexSelection()
        codexHandoffTask?.cancel()
        let handoffID = UUID()
        codexHandoffID = handoffID
        presentation.setProfileTransitioning(true)
        codexHandoffTask = Task { [weak self] in
            guard let self else { return }
            await completeCodexHandoff(to: selection)
            guard codexHandoffID == handoffID else { return }
            codexHandoffTask = nil
            codexHandoffID = nil
            presentation.setProfileTransitioning(false)
        }
    }

    private func completeCodexHandoff(
        to selection: TurboCodeProfileSelection
    ) async {
        guard let threadID = conversations.activeThreadID else {
            _ = applyTurboCodeSelection(selection)
            await rebuildSession(discardingCapabilityContext: true)
            return
        }
        let handoffWorkspaceRoot = workspace.root
        let handoff = await codexRuntime.prepareHandoff(
            turboThreadID: threadID,
            blocks: timeline.blocks,
            workspaceRoot: handoffWorkspaceRoot
        )
        guard !Task.isCancelled,
              conversations.activeThreadID == threadID,
              workspace.root == handoffWorkspaceRoot,
              applyTurboCodeSelection(selection) else { return }
        if handoff.didSummarize {
            timeline.blocks.append(
                ChatBlock(
                    kind: .compaction,
                    text: "Codex context summarized for the selected TurboCode profile."
                )
            )
        }
        await codexRuntime.completeHandoff(
            turboThreadID: threadID,
            boundaryBlockID: timeline.blocks.last?.id
        )
        await rebuildSession(
            keepingHistory: false,
            discardingCapabilityContext: true,
            restoringHistory: handoff.history
        )
    }

    private func applyTurboCodeSelection(
        _ selection: TurboCodeProfileSelection
    ) -> Bool {
        switch selection {
        case .backend(let backend): modelRuntime.selectBackend(backend)
        case .remoteModel(let id): modelRuntime.selectRemoteModel(id: id)
        case .builtIn(let id): modelRuntime.selectBuiltInProfile(id)
        case .dynamic(let id): modelRuntime.selectDynamicProfile(id)
        }
    }

    private func restoreCodexImportedContext() async {
        guard let threadID = conversations.activeThreadID else { return }
        await codexRuntime.restoreImportedContext(
            turboThreadID: threadID,
            blocks: timeline.blocks
        )
    }
}
