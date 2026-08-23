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
        lifecycle: ConversationLifecycleCoordinator
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

    func send(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool
    ) async {
        guard !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !runtimeProjection.hasActiveOperation,
              !presentation.isProfileTransitioning,
              modelRuntime.activeBackend != .codex || codexRuntime.canSend else {
            return
        }

        await compactOnDeviceContextIfNeeded()
        await lifecycle.ensureActiveThread()
        let turnID = TurnID()
        let titleThreadID = conversations.activeThreadID
        // Routing is immutable for the accepted turn. A later menu selection
        // cannot redirect this operation after provider execution begins.
        let responseBackend = modelRuntime.activeBackend
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
                guard visibleInTimeline,
                      let self,
                      let titleThreadID else { return }
                // Optional title inference starts only after response ownership
                // is released, so it can never leave the composer on Stop.
                await generateTitle(from: displayText, threadID: titleThreadID)
                await sessions.persistGeneratedTitle(id: titleThreadID)
            }
        )
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
        guard modelRuntime.applyAgentTuning(value) else { return }
        await profiles.rebuildSession(discardingCapabilityContext: true)
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
