import Foundation

/// Non-observable composition root for the chat application domains.
///
/// Keeping construction here lets `ChatStore` remain a compatibility façade
/// without making its observable lifetime responsible for assembling provider,
/// workspace, persistence, and coordinator graphs.
@MainActor
final class ChatApplicationAssembly {
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
    let llmRuntime: LLMRuntime
    let onDeviceToolCallingSupported: Bool
    let responseCoordinator: ChatResponseCoordinator
    let sessionCoordinator: ConversationSessionCoordinator
    let conversationPersistence: ConversationPersistenceService
    let profileSelectionCoordinator: ProfileSelectionCoordinator
    let conversationLifecycleCoordinator: ConversationLifecycleCoordinator
    let workspaceLifecycleCoordinator: WorkspaceLifecycleCoordinator
    let independentTaskCoordinator: IndependentTaskCoordinator
    let messageSendCoordinator: MessageSendCoordinator
    let editorialDeskAssembly: EditorialDeskAssembly
    let reviewCoordinator: ReviewCoordinator

    init(
        conversationRepository: any ConversationRepository,
        gitService: any GitRepositoryServicing,
        diffPatchService: any DiffPatchApplying,
        workspaceDefaults: UserDefaults
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
        let sessionCoordinator = ConversationSessionCoordinator(
            conversations: conversations,
            timeline: timeline,
            modelRuntime: modelRuntime,
            llmRuntime: llmRuntime,
            persistence: conversationPersistence
        )
        let reviewCoordinator = ReviewCoordinator(
            timeline: timeline,
            workbench: workbench,
            workspace: workspace,
            gitService: gitService,
            diffPatchService: diffPatchService
        )
        let responseCoordinator = ChatResponseCoordinator(
            timeline: timeline,
            toolInteractions: toolInteractions,
            agentActivity: agentActivity,
            agentRuntime: agentRuntime,
            llmRuntime: llmRuntime,
            reviewCoordinator: reviewCoordinator,
            workspaceNameProvider: {
                workspace.label.isEmpty ? nil : workspace.label
            },
            activityPresentationRequested: {
                workbench.rightPanelMode = .activity
            }
        )
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
        let workspaceLifecycleCoordinator = WorkspaceLifecycleCoordinator(
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
        let independentTaskCoordinator = IndependentTaskCoordinator(
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

        self.workspaceStore = workspace
        self.conversationStore = conversations
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
        self.responseCoordinator = responseCoordinator
        self.sessionCoordinator = sessionCoordinator
        self.conversationPersistence = conversationPersistence
        self.profileSelectionCoordinator = profileSelectionCoordinator
        self.conversationLifecycleCoordinator = conversationLifecycleCoordinator
        self.workspaceLifecycleCoordinator = workspaceLifecycleCoordinator
        self.independentTaskCoordinator = independentTaskCoordinator
        self.messageSendCoordinator = messageSendCoordinator
        self.editorialDeskAssembly = EditorialDeskAssembly(
            runtime: llmRuntime,
            modelRuntime: modelRuntime,
            codexRuntime: codexRuntime,
            messageSender: messageSendCoordinator
        )
        self.reviewCoordinator = reviewCoordinator
    }
}
