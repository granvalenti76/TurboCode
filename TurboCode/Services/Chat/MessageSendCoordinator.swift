import Foundation

/// Owns ordinary native and Codex message turns from prompt preparation through
/// post-release title persistence. Provider execution remains behind
/// `ChatResponseCoordinator`/`LLMRuntime`; this application coordinator captures
/// UI inputs once and never makes a provider task depend on repaint cadence.
@MainActor
final class MessageSendCoordinator {
    private let runtime: AgentRuntime
    private let llmRuntime: LLMRuntime
    private let titleGenerator: any ConversationTitleGenerating
    private let invokerFactory: AgentTaskInvokerFactory
    private let runtimeProjection: AgentRuntimeProjectionStore
    private let responseCoordinator: ChatResponseCoordinator
    private let modelRuntime: ModelRuntimeStore
    private let codexRuntime: CodexRuntimeStore
    private let conversations: ConversationStore
    private let timeline: ChatTimelineStore
    private let workspace: WorkspaceStore
    private let presentation: ChatPresentationViewModel
    private let sessions: ConversationSessionCoordinator
    private let profiles: ProfileSelectionCoordinator
    private let lifecycle: ConversationLifecycleCoordinator
    private let steering: SteeringCoordinator

    init(
        runtime: AgentRuntime,
        llmRuntime: LLMRuntime,
        titleGenerator: any ConversationTitleGenerating,
        invokerFactory: AgentTaskInvokerFactory,
        runtimeProjection: AgentRuntimeProjectionStore,
        responseCoordinator: ChatResponseCoordinator,
        modelRuntime: ModelRuntimeStore,
        codexRuntime: CodexRuntimeStore,
        conversations: ConversationStore,
        timeline: ChatTimelineStore,
        workspace: WorkspaceStore,
        presentation: ChatPresentationViewModel,
        sessions: ConversationSessionCoordinator,
        profiles: ProfileSelectionCoordinator,
        lifecycle: ConversationLifecycleCoordinator,
        steering: SteeringCoordinator
    ) {
        self.runtime = runtime
        self.llmRuntime = llmRuntime
        self.titleGenerator = titleGenerator
        self.invokerFactory = invokerFactory
        self.runtimeProjection = runtimeProjection
        self.responseCoordinator = responseCoordinator
        self.modelRuntime = modelRuntime
        self.codexRuntime = codexRuntime
        self.conversations = conversations
        self.timeline = timeline
        self.workspace = workspace
        self.presentation = presentation
        self.sessions = sessions
        self.profiles = profiles
        self.lifecycle = lifecycle
        self.steering = steering
    }

    func preparePrompt(for text: String) async -> String? {
        await refreshSkillsIfNeeded()
        if modelRuntime.activeBackend != .codex,
           modelRuntime.workspaceInstructionsChanged(in: workspace.root) {
            // Session instructions are immutable. Replace only the stale
            // capability prefix while preserving visible conversation history.
            await profiles.rebuildSession()
        }
        return modelRuntime.resolvedPrompt(for: text)
    }

    /// Records an application-owned file receipt without entering the model
    /// runtime. Editorial publication is a filesystem event, not a user turn;
    /// persisting it here keeps the widget available after session restore.
    func presentEditorialPublication(_ publication: EditorialPublicationBlock) async {
        await lifecycle.ensureActiveThread()
        timeline.presentEditorialPublication(publication)
        guard let threadID = conversations.activeThreadID else { return }
        conversations.touchThread(id: threadID)
        await sessions.persistActiveSession(id: threadID)
    }

    /// Returns whether the turn was admitted. Keeping admission explicit lets
    /// feature adapters report a rejected handoff instead of treating a
    /// silent guard return as a successful publish.
    func send(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool
    ) async -> Bool {
        guard !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !runtimeProjection.hasActiveOperation,
              !presentation.isProfileTransitioning,
              modelRuntime.activeBackend != .codex || codexRuntime.canSend else {
            return false
        }

        await compactOnDeviceContextIfNeeded()
        await lifecycle.ensureActiveThread()
        let turnID = TurnID()
        let titleThreadID = conversations.activeThreadID
        // Routing is immutable for the accepted turn. A later menu selection
        // cannot redirect this operation after provider execution begins.
        let responseBackend = modelRuntime.activeBackend
        let steering = self.steering
        await runtime.runOperation(
            turnID: turnID,
            operation: { [weak self] in
                guard let self else { return }
                if responseBackend == .codex {
                    await performCodex(
                        displayText: displayText,
                        promptText: promptText,
                        visibleInTimeline: visibleInTimeline,
                        turnID: turnID
                    )
                } else {
                    await performNative(
                        displayText: displayText,
                        promptText: promptText,
                        visibleInTimeline: visibleInTimeline,
                        turnID: turnID
                    )
                }
            },
            afterRelease: { [weak self] in
                guard let self else { return }
                await steering.deliverAutomatically(after: turnID)
                guard visibleInTimeline,
                      let titleThreadID else { return }
                // Optional title inference starts only after response ownership
                // is released, so it can never leave the composer on Stop.
                await generateTitle(from: displayText, threadID: titleThreadID)
                await sessions.persistGeneratedTitle(id: titleThreadID)
            }
        )
        return true
    }

    /// Runs one native continuation for a claimed steering batch. The batch is
    /// already owned by `SteeringCoordinator`; this method only starts a new
    /// operation after the previous provider session has fully unwound.
    func deliverSteering(
        batch: SteeringDeliveryBatch,
        requests: [SteeringRequest]
    ) async -> SteeringCoordinator.DeliveryResult {
        let backend = batch.context.providerSelection.backend
        guard conversations.activeThreadID == batch.context.conversationID,
              modelRuntime.activeBackend == backend,
              await runtime.ownsSteeringDelivery(batch) else {
            return .failed(
                TurnFailure(
                    code: "steering.stale_context",
                    message: "The conversation context changed before delivery.",
                    isRecoverable: true
                )
            )
        }

        let ordered = requests.sorted { $0.sequence < $1.sequence }
        let displayText = ordered.map(\.text).joined(separator: "\n\n")
        let promptText = ordered.map { request in
            "Steering instruction \(request.sequence):\n\(request.text)"
        }.joined(separator: "\n\n")
        let turnID = TurnID()
        let modelName = batch.context.providerSelection.modelName
            ?? modelRuntime.composerModel
        let request = TurnRequest(
            id: turnID,
            prompt: promptText,
            backend: backend,
            modelName: modelName,
            workspaceRoot: batch.context.workspaceRoot
        )
        let metadata = SteeringDeliveryMetadata(
            requestIDs: batch.requestIDs,
            deliveryID: batch.id,
            providerTurnID: turnID.rawValue
        )
        timeline.presentSteeringDelivery(
            displayText: displayText,
            metadata: metadata
        )
        guard await runtime.apply(.started(request)) else {
            return .failed(
                TurnFailure(
                    code: "steering.continuation_not_admitted",
                    message: "The steering continuation could not be admitted.",
                    isRecoverable: true
                )
            )
        }

        let responseCoordinator = self.responseCoordinator
        let timeline = self.timeline
        let mode = modelRuntime.orchestratorMode
        let workspaceKind = self.workspaceKind
        let serverURL = backend == .llamaServer
            ? modelRuntime.activeRemoteModel?.url
            : nil
        let resultBox = SteeringResultBox()
        let admitted = await runtime.runOperation(
            turnID: turnID,
            operationKind: .conversational,
            operation: { [weak self] in
                guard let self else { return }
                let result: ChatResponseCoordinator.Result
                if backend == .codex {
                    await self.performCodex(
                        displayText: displayText,
                        promptText: promptText,
                        visibleInTimeline: true,
                        turnID: turnID
                    )
                    switch await self.runtime.currentTurnState?.outcome {
                    case .succeeded:
                        result = ChatResponseCoordinator.Result(
                            errorMessage: nil,
                            touchedConversation: true
                        )
                    case .failed(let failure):
                        result = ChatResponseCoordinator.Result(
                            errorMessage: failure.message,
                            touchedConversation: false
                        )
                    case .cancelled:
                        result = ChatResponseCoordinator.Result(
                            errorMessage: "The steering continuation was cancelled.",
                            touchedConversation: false
                        )
                    case nil:
                        result = ChatResponseCoordinator.Result(
                            errorMessage: "The steering continuation did not settle.",
                            touchedConversation: false
                        )
                    }
                } else {
                    result = await responseCoordinator.performNative(
                        displayText: displayText,
                        promptText: promptText,
                        visibleInTimeline: false,
                        turnID: turnID,
                        blocks: timeline.blocks,
                        backend: backend,
                        mode: mode,
                        workspaceKind: workspaceKind,
                        workspaceRoot: batch.context.workspaceRoot,
                        modelName: modelName,
                        serverURL: serverURL,
                        contextChanged: { usage in
                            guard backend == .llamaServer else {
                                return
                            }
                            self.presentation.setLlamaContextUsage(usage)
                        }
                    )
                }
                await resultBox.set(result)
            },
            afterRelease: { [weak self] in
                guard let self else { return }
                await steering.deliverAutomatically(after: turnID)
            }
        )
        guard admitted, let result = await resultBox.value else {
            return .failed(
                TurnFailure(
                    code: "steering.continuation_not_admitted",
                    message: "The steering continuation could not start.",
                    isRecoverable: true
                )
            )
        }
        guard result.errorMessage == nil, result.touchedConversation else {
            return .failed(
                TurnFailure(
                    code: "steering.continuation_failed",
                    message: result.errorMessage
                        ?? "The steering continuation did not complete.",
                    isRecoverable: true
                )
            )
        }
        if let conversationID = conversations.activeThreadID {
            await sessions.persistActiveSession(id: conversationID)
        }
        return .accepted(providerTurnID: turnID.rawValue)
    }

    func generateTitle(from prompt: String, threadID: String? = nil) async {
        guard let threadID = threadID ?? conversations.activeThreadID,
              conversations.threads.contains(where: {
                  $0.id == threadID && $0.title == "New Chat"
              }) else { return }
        if let title = await titleGenerator.generateTitle(from: prompt) {
            conversations.applyGeneratedTitle(title, to: threadID)
        }
    }

    func reloadSkills() async {
        await refreshSkillsIfNeeded(forceRebuild: true)
    }

    func applyAgentTuning(_ value: AgentTuningConfig) async {
        // The facade owns the complete settings boundary: it updates the
        // plugin snapshot and performs one rebuild after all capabilities are
        // known. Rebuilding here first would race plugin activation during app
        // startup and could leave the first turn in a permanent busy state.
        _ = modelRuntime.applyAgentTuning(value)
    }

    func refreshSkillsIfNeeded(forceRebuild: Bool = false) async {
        await profiles.refreshSkillsIfNeeded(forceRebuild: forceRebuild)
    }

    private func compactOnDeviceContextIfNeeded() async {
        guard modelRuntime.activeBackend == .foundationApple else { return }
        guard let transcript = await llmRuntime.foundationModelsTranscript() else {
            return
        }
        let turnCount = SessionRebuildHistory.userTurnCount(in: transcript)
        guard turnCount >= SessionRebuildHistory.onDeviceCompactionThreshold,
              let compaction = SessionRebuildHistory.onDeviceCompaction(
                  from: timeline.blocks
              ) else { return }

        timeline.presentCompaction(compaction.summary)
        await profiles.rebuildSession(restoringHistory: compaction.history)
        Task {
            await AgentDiagnosticsRecorder.shared.recordCompaction(
                turnCount: turnCount,
                retainedCharacters: compaction.summary.count
            )
        }
    }

    private func performCodex(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool,
        turnID: TurnID
    ) async {
        presentation.errorMessage = nil
        guard let threadID = conversations.activeThreadID else {
            presentation.errorMessage = "TurboCode could not create the conversation."
            return
        }
        let profile = modelRuntime.activeDynamicProfile
        let tuning = modelRuntime.agentTuning
        // Worker construction belongs to the application factory. The
        // observable store contributes only one immutable configuration value.
        let delegationConfiguration = profile?.usesDelegation == true
            ? modelRuntime.makeSessionConfiguration(workspaceRoot: workspace.root)
            : nil
        let result = await responseCoordinator.performCodex(
            displayText: displayText,
            promptText: promptText,
            visibleInTimeline: visibleInTimeline,
            turnID: turnID,
            turboThreadID: threadID,
            workspaceRoot: workspace.root,
            workspaceName: workspace.root.isEmpty ? nil : workspace.label,
            mode: modelRuntime.orchestratorMode,
            workspaceKind: workspaceKind,
            agentTuning: tuning,
            availableSkills: DynamicProfileRuntimeSelection.skills(
                from: modelRuntime.availableSkills,
                profile: profile,
                safariMCPEnabled: tuning.experimental.safariMCPEnabled
            ),
            pluginTools: modelRuntime.activePluginTools,
            codexModelID: profile?.codexModelID,
            codexReasoningEffort: profile?.codexReasoningEffort,
            delegationInvoker: invokerFactory.makeDelegateInvoker(
                configuration: delegationConfiguration,
                events: responseCoordinator.modelSessionEvents
            ),
            modelName: modelRuntime.composerModel
        )
        modelRuntime.composerModel = profile?.name
            ?? "Codex · \(codexRuntime.displayName)"
        presentation.errorMessage = result.errorMessage
        if result.touchedConversation {
            conversations.touchThread(id: threadID)
        }
        await refreshSkillsIfNeeded()
        await sessions.persistActiveSession(id: threadID)
    }

    private func performNative(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool,
        turnID: TurnID
    ) async {
        let conversationID = conversations.activeThreadID
        presentation.runtimeStatus = .ready
        presentation.errorMessage = nil
        let backend = modelRuntime.activeBackend
        let result = await responseCoordinator.performNative(
            displayText: displayText,
            promptText: promptText,
            visibleInTimeline: visibleInTimeline,
            turnID: turnID,
            blocks: timeline.blocks,
            backend: backend,
            mode: modelRuntime.orchestratorMode,
            workspaceKind: workspaceKind,
            workspaceRoot: workspace.root,
            modelName: modelRuntime.composerModel,
            serverURL: backend == .llamaServer
                ? modelRuntime.activeRemoteModel?.url
                : nil,
            contextChanged: { [weak self] usage in
                guard let self, modelRuntime.activeBackend == .llamaServer else { return }
                presentation.setLlamaContextUsage(usage)
            }
        )
        presentation.errorMessage = result.errorMessage
        if result.touchedConversation, let conversationID {
            conversations.touchThread(id: conversationID)
        }
        await refreshSkillsIfNeeded()
        if let conversationID,
           conversations.activeThreadID == conversationID {
            await sessions.persistActiveSession(id: conversationID)
        }
    }

    private var workspaceKind: String {
        guard !workspace.root.isEmpty else { return "none" }
        let marker = URL(fileURLWithPath: workspace.root).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: marker.path) ? "git" : "nonGit"
    }

}

/// Sendable handoff for the result produced inside the detached runtime
/// operation. The coordinator remains the only owner of provider execution.
private actor SteeringResultBox {
    private var storedResult: ChatResponseCoordinator.Result?

    func set(_ result: ChatResponseCoordinator.Result) {
        storedResult = result
    }

    var value: ChatResponseCoordinator.Result? {
        storedResult
    }
}
