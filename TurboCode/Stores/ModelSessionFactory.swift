import Foundation
import FoundationModels
import FoundationModelsUtilities

struct ModelSessionConfiguration {
    let backend: ModelBackend
    let activeRemoteModel: RemoteModelConfig?
    let delegateRemoteModel: RemoteModelConfig
    let orchestratorMode: OrchestratorMode
    let workspaceRoot: String
    let agentTuning: AgentTuningConfig
    let availableSkills: [TurboCodeSkillDefinition]
    let activeDynamicProfile: UserDynamicProfile?
    let skillActivations: SkillActivations
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let delegateReasoningLevel: ContextOptions.ReasoningLevel?
    let activeTemperature: Double?
    let delegateTemperature: Double?
    /// `nil` keeps the default complete worker catalog; a value is an
    /// explicit profile-owned allowlist, including an intentionally empty one.
    let delegateToolIDs: Set<ToolCapabilityID>?
    let dropsCompletedToolCalls: Bool
    let workspaceInstructions: WorkspaceInstructions?
}

struct ModelSessionEvents {
    let toolStarted: @Sendable (
        Transcript.ToolCall,
        ModelBackend,
        AgentActivityToolOwner
    ) async -> Void
    let toolFinished: @Sendable (
        Transcript.ToolCall,
        Transcript.ToolOutput,
        ModelBackend,
        AgentActivityToolOwner
    ) async -> Void
    let delegationChanged: @Sendable (Bool) async -> Void
    let agentActivityChanged: @Sendable (
        AgentActivityRuntimeEvent
    ) async -> Void

    init(
        toolStarted: @escaping @Sendable (
            Transcript.ToolCall,
            ModelBackend,
            AgentActivityToolOwner
        ) async -> Void,
        toolFinished: @escaping @Sendable (
            Transcript.ToolCall,
            Transcript.ToolOutput,
            ModelBackend,
            AgentActivityToolOwner
        ) async -> Void,
        delegationChanged: @escaping @Sendable (Bool) async -> Void,
        agentActivityChanged: @escaping @Sendable (
            AgentActivityRuntimeEvent
        ) async -> Void = { _ in }
    ) {
        self.toolStarted = toolStarted
        self.toolFinished = toolFinished
        self.delegationChanged = delegationChanged
        self.agentActivityChanged = agentActivityChanged
    }
}

struct ResolvedModelCapabilities {
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let toolAccess: ModelToolTier
}

private struct ToollessProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: any LanguageModel
    let temperature: Double?
    let samplingMode: GenerationOptions.SamplingMode?
    let reasoningLevel: ContextOptions.ReasoningLevel?

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
        }
        .model(model)
        .temperature(temperature)
        .samplingMode(samplingMode)
        .reasoningLevel(reasoningLevel)
    }
}

/// Converts product intent into capabilities that a concrete model can accept.
/// This is the extension point for future model classes and richer tool tiers:
/// profiles consume this resolved policy instead of assuming every backend can
/// use every option or tool.
enum ModelCapabilityPolicy {
    static func resolve(
        for model: any LanguageModel,
        requestedReasoningLevel: ContextOptions.ReasoningLevel?,
        preferredToolAccess: ModelToolTier = .standard
    ) -> ResolvedModelCapabilities {
        let capabilities = model.capabilities
        return ResolvedModelCapabilities(
            reasoningLevel: capabilities.contains(.reasoning)
                ? requestedReasoningLevel
                : nil,
            toolAccess: capabilities.contains(.toolCalling) ? preferredToolAccess : .none
        )
    }
}

/// Owns the construction of Foundation Models sessions, profiles, tools and
/// system instructions. ChatStore only supplies current application state and
/// receives lifecycle events used to update its observable UI state.
enum ModelSessionFactory {
    static func makeSession(
        configuration: ModelSessionConfiguration,
        history: [Transcript.Entry],
        events: ModelSessionEvents
    ) -> LanguageModelSession {
        let activeModel = activeModel(for: configuration)
        let activeRemoteConfiguration = configuration.backend == .foundationApple
            ? nil
            : (configuration.activeRemoteModel ?? RemoteModelConfig.fallbackLlama)
        let activeCapabilities = ModelCapabilityPolicy.resolve(
            for: activeModel,
            requestedReasoningLevel: configuration.reasoningLevel,
            preferredToolAccess: preferredToolTier(
                backend: configuration.backend,
                remoteModel: activeRemoteConfiguration
            )
        )
        let samplingMode = profileSamplingMode(configuration.activeDynamicProfile)
        let temperature = samplingMode == nil ? configuration.activeTemperature : nil
        let routing = ModelRoutingPolicy.resolve(
            backend: configuration.backend,
            mode: configuration.orchestratorMode,
            activeProfile: configuration.activeDynamicProfile
        )

        if routing.role == .experimentalOnDeviceCoordinator,
           activeCapabilities.toolAccess != .none {
            return makeOrchestratorSession(
                configuration: configuration,
                activeModel: activeModel,
                activeCapabilities: activeCapabilities,
                history: history,
                events: events
            )
        }

        guard activeCapabilities.toolAccess != .none else {
            return makeToollessSession(
                instructions: systemPrompt(
                    for: configuration,
                    role: routing.role == .microtaskOnDevice
                        ? .microtask
                        : .standalone,
                    backend: configuration.backend,
                    plan: nil
                ),
                model: activeModel,
                temperature: temperature,
                samplingMode: samplingMode,
                reasoningLevel: activeCapabilities.reasoningLevel,
                history: history
            )
        }

        let standalonePlan = ModelToolCatalog.plan(
            profile: routing.profile,
            tier: activeCapabilities.toolAccess,
            context: toolContext(
                for: configuration,
                repositoryMap: activeRemoteConfiguration?.repositoryMap
            ),
            selectedIDs: configuration.activeDynamicProfile?.resolvedToolIDs
        )
        let usesExclusiveToolSelection = configuration.activeDynamicProfile != nil
        let instructions = systemPrompt(
            for: configuration,
            role: routing.role == .microtaskOnDevice ? .microtask : .standalone,
            backend: configuration.backend,
            plan: standalonePlan
        )
        var standaloneTools = toolInstances(
            for: standalonePlan,
            configuration: configuration,
            including: usesExclusiveToolSelection ? nil : [
                    .turboCodeGuide,
                    .listWorkspace,
                    .swiftWorkspaceMap,
                    .xcodeProject,
                    .writeOnDevice,
                    .removeFile,
                    .createSkill
                ],
            repositoryMapContextTokens: activeRemoteConfiguration?.contextWindowTokens
                ?? 32_768
        )
        if standalonePlan.contains(.delegateTask) {
            // Profiles that explicitly include delegate_task receive the
            // production structured coordinator adapter; direct profiles do not.
            standaloneTools.append(
                DelegateTaskTool(
                    invoker: makeDelegateInvoker(
                        configuration: configuration,
                        events: events
                    )
                )
            )
        }

        return LanguageModelSession(
            profile: StandaloneProfile(
                instructions: instructions,
                activations: configuration.skillActivations,
                diskSkills: configuration.availableSkills,
                workspaceRoot: configuration.workspaceRoot,
                model: activeModel,
                temperature: temperature,
                samplingMode: samplingMode,
                reasoningLevel: activeCapabilities.reasoningLevel,
                dropsCompletedToolCalls: configuration.dropsCompletedToolCalls,
                usesCacheStableToolDefinitions:
                    activeRemoteConfiguration?.reasoningTransport == .deepseekThinking,
                executionPolicy: configuration.agentTuning.execution,
                gitPolicy: configuration.agentTuning.git,
                toolPlan: standalonePlan,
                usesExclusiveToolSelection: usesExclusiveToolSelection,
                supplementalTools: standaloneTools,
                onToolStart: { call in
                    await events.toolStarted(
                        call,
                        configuration.backend,
                        .coordinator
                    )
                },
                onToolEnd: { call, output in
                    await events.toolFinished(
                        call,
                        output,
                        configuration.backend,
                        .coordinator
                    )
                }
            ),
            history: history
        )
    }

    static func profileSamplingMode(
        _ profile: UserDynamicProfile?
    ) -> GenerationOptions.SamplingMode? {
        guard let profile, profile.greedyMode, profile.baseModelID != .deepseek else {
            return nil
        }
        return .greedy
    }

    private static func makeOrchestratorSession(
        configuration: ModelSessionConfiguration,
        activeModel: any LanguageModel,
        activeCapabilities: ResolvedModelCapabilities,
        history: [Transcript.Entry],
        events: ModelSessionEvents
    ) -> LanguageModelSession {
        let delegateBackend = backend(for: configuration.delegateRemoteModel.role)
        let delegateModel = providerModel(for: configuration.delegateRemoteModel)
        let delegateCapabilities = ModelCapabilityPolicy.resolve(
            for: delegateModel,
            requestedReasoningLevel: configuration.delegateReasoningLevel,
            preferredToolAccess: preferredToolTier(
                backend: backend(for: configuration.delegateRemoteModel.role),
                remoteModel: configuration.delegateRemoteModel
            )
        )
        let delegatePlan = ModelToolCatalog.plan(
            profile: .delegate,
            tier: delegateCapabilities.toolAccess,
            context: toolContext(
                for: configuration,
                repositoryMap: configuration.delegateRemoteModel.repositoryMap
            )
        )
        let delegateInstructions = systemPrompt(
            for: configuration,
            role: .delegate,
            backend: delegateBackend,
            plan: delegatePlan
        )
        let powerfulTool = CallPowerfulModelTool(
            model: delegateModel,
            temperature: configuration.delegateTemperature,
            reasoningLevel: delegateCapabilities.reasoningLevel,
            delegateTools: toolInstances(
                for: delegatePlan,
                configuration: configuration,
                repositoryMapContextTokens: configuration.delegateRemoteModel.contextWindowTokens
            ),
            delegateInstructions: delegateInstructions,
            onToolStart: { call in
                await events.toolStarted(call, delegateBackend, .worker)
            },
            onToolEnd: { call, output in
                await events.toolFinished(
                    call,
                    output,
                    delegateBackend,
                    .worker
                )
            },
            coordinator: AgentActivityAgent(
                modelName: "Apple On-Device",
                role: .experimentalOnDeviceCoordinator
            ),
            worker: AgentActivityAgent(
                modelName: configuration.delegateRemoteModel.name,
                role: .codingWorker
            ),
            activityChanged: events.agentActivityChanged
        )

        let orchestratorPlan = ModelToolCatalog.plan(
            profile: .orchestrator,
            tier: activeCapabilities.toolAccess,
            context: toolContext(for: configuration, repositoryMap: nil)
        )
        var orchestratorTools = toolInstances(
            for: orchestratorPlan,
            configuration: configuration
        )
        if orchestratorPlan.contains(.callPowerfulModel) {
            orchestratorTools.append(powerfulTool)
        }
        let orchestratorInstructions = systemPrompt(
            for: configuration,
            role: .orchestrator,
            backend: .foundationApple,
            plan: orchestratorPlan
        )

        return LanguageModelSession(
            profile: TurboCodeDynamicProfile(
                instructions: orchestratorInstructions,
                tools: orchestratorTools,
                model: activeModel,
                onToolStart: { call in
                    await events.toolStarted(
                        call,
                        .foundationApple,
                        .coordinator
                    )
                },
                onToolEnd: { call, output in
                    await events.toolFinished(
                        call,
                        output,
                        .foundationApple,
                        .coordinator
                    )
                },
                onDelegationStart: {
                    await events.delegationChanged(true)
                },
                onDelegationEnd: {
                    await events.delegationChanged(false)
                },
                reasoningLevel: activeCapabilities.reasoningLevel
            ),
            history: history
        )
    }

    private static func makeToollessSession(
        instructions: String,
        model: any LanguageModel,
        temperature: Double?,
        samplingMode: GenerationOptions.SamplingMode?,
        reasoningLevel: ContextOptions.ReasoningLevel?,
        history: [Transcript.Entry]
    ) -> LanguageModelSession {
        LanguageModelSession(
            profile: ToollessProfile(
                instructions: instructions,
                model: model,
                temperature: temperature,
                samplingMode: samplingMode,
                reasoningLevel: reasoningLevel
            ),
            history: history
        )
    }

    static func toolInstances(
        for plan: ModelToolPlan,
        configuration: ModelSessionConfiguration,
        including allowedIDs: Set<ToolCapabilityID>? = nil,
        repositoryMapContextTokens: Int = 32_768
    ) -> [any Tool] {
        plan.assignments.compactMap { assignment -> (any Tool)? in
            guard assignment.isRegistered,
                  allowedIDs?.contains(assignment.id) ?? true else { return nil }
            switch assignment.id {
            case .turboCodeGuide:
                return TurboCodeGuideTool(store: .live)
            case .listWorkspace:
                return ListWorkspaceTool(
                    workspaceRoot: configuration.workspaceRoot,
                    // Only llama-server models need an explicit continuation
                    // hint after discovering an Xcode container.
                    suggestsXcodeAnalysisTools: configuration.backend == .llamaServer
                )
            case .swiftWorkspaceMap:
                return SwiftWorkspaceMapTool(
                    workspaceRoot: configuration.workspaceRoot,
                    detail: plan.tier == .enhanced ? .enhanced : .compact,
                    contextWindowTokens: repositoryMapContextTokens
                )
            case .readFile:
                return ReadFileTool(workspaceRoot: configuration.workspaceRoot)
            case .searchWorkspace:
                return GrepTool(workspaceRoot: configuration.workspaceRoot)
            case .fileSystem:
                return FileSystemTool(workspaceRoot: configuration.workspaceRoot)
            case .git:
                return GitTool(
                    workspaceRoot: configuration.workspaceRoot,
                    policy: configuration.agentTuning.git,
                    executionPolicy: configuration.agentTuning.execution
                )
            case .bash:
                return BashTool(
                    workspaceRoot: configuration.workspaceRoot,
                    executionPolicy: configuration.agentTuning.execution
                )
            case .swiftPackageManager:
                return SwiftPackageManagerTool(
                    workspaceRoot: configuration.workspaceRoot,
                    executionPolicy: configuration.agentTuning.execution
                )
            case .xcodeProject:
                return XcodeProjectTool(
                    workspaceRoot: configuration.workspaceRoot,
                    executionPolicy: configuration.agentTuning.execution,
                    enhancedOutput: plan.tier == .enhanced
                )
            case .editFile:
                // Keep revision-bound edits on their dedicated implementation;
                // coordinator routing must not change workspace safety semantics.
                return EditFileTool(workspaceRoot: configuration.workspaceRoot)
            case .writeOnDevice:
                // The constrained on-device writer remains distinct from the
                // broader edit tool so its intentionally small schema survives.
                return WriteOnDeviceTool(workspaceRoot: configuration.workspaceRoot)
            case .removeFile:
                return RemoveFileTool(workspaceRoot: configuration.workspaceRoot)
            case .loadSkill:
                guard !configuration.availableSkills.isEmpty else { return nil }
                return LoadSkillTool(skills: configuration.availableSkills)
            case .createSkill:
                guard !configuration.workspaceRoot.isEmpty else { return nil }
                return CreateSkillTool(workspaceRoot: configuration.workspaceRoot)
            case .delegateTask, .callPowerfulModel:
                return nil
            }
        }
    }

    /// Builds the shared worker invocation used by every coordinator adapter.
    /// Provider bridges should depend on this boundary instead of recreating
    /// worker model, tool-plan, or event wiring.
    static func makeDelegateInvoker(
        configuration: ModelSessionConfiguration,
        events: ModelSessionEvents,
        runner: (any AgentTaskRunning)? = nil
    ) -> ConfiguredAgentTaskInvoker {
        let delegateModel = providerModel(for: configuration.delegateRemoteModel)
        let delegateBackend = backend(for: configuration.delegateRemoteModel.role)
        let capabilities = ModelCapabilityPolicy.resolve(
            for: delegateModel,
            requestedReasoningLevel: configuration.delegateReasoningLevel,
            preferredToolAccess: preferredToolTier(
                backend: delegateBackend,
                remoteModel: configuration.delegateRemoteModel
            )
        )
        let plan = ModelToolCatalog.plan(
            profile: .delegate,
            tier: capabilities.toolAccess,
            context: toolContext(
                for: configuration,
                repositoryMap: configuration.delegateRemoteModel.repositoryMap
            ),
            selectedIDs: configuration.delegateToolIDs
        )
        let resolvedRunner = runner ?? BoundedAgentTaskRunner(
            verifier: XcodeAgentTaskVerifier(
                executionPolicy: configuration.agentTuning.execution,
                enhancedOutput: capabilities.toolAccess == .enhanced
            )
        )
        return ConfiguredAgentTaskInvoker(
            runner: resolvedRunner,
            context: AgentTaskRunContext(
                model: delegateModel,
                tools: toolInstances(
                    for: plan,
                    configuration: configuration,
                    repositoryMapContextTokens:
                        configuration.delegateRemoteModel.contextWindowTokens
                ),
                workspaceRoot: configuration.workspaceRoot,
                instructions: systemPrompt(
                    for: configuration,
                    role: .delegate,
                    backend: delegateBackend,
                    plan: plan
                ),
                temperature: configuration.delegateTemperature,
                reasoningLevel: capabilities.reasoningLevel
            ),
            events: AgentTaskRunnerEvents(
                toolStarted: { event in
                    await events.agentActivityChanged(
                        .toolStarted(
                            taskID: event.taskID,
                            attemptID: event.attemptID,
                            tool: AgentActivityRuntimeMapping.tool(
                                from: event.call,
                                owner: .worker
                            )
                        )
                    )
                    await events.toolStarted(
                        event.call,
                        delegateBackend,
                        .worker
                    )
                },
                toolFinished: { event in
                    await events.agentActivityChanged(
                        .toolFinished(
                            taskID: event.taskID,
                            attemptID: event.attemptID,
                            callID: event.call.id
                        )
                    )
                    await events.toolFinished(
                        event.call,
                        event.output,
                        delegateBackend,
                        .worker
                    )
                },
                verificationStarted: { taskID, attemptID, _ in
                    await events.agentActivityChanged(
                        .phaseChanged(
                            taskID: taskID,
                            attemptID: attemptID,
                            phase: .verifying
                        )
                    )
                }
            ),
            coordinator: AgentActivityAgent(
                modelName: configuration.activeDynamicProfile?.name
                    ?? configuration.activeRemoteModel?.name
                    ?? "Coordinator",
                role: .powerfulCoordinator
            ),
            worker: AgentActivityAgent(
                modelName: configuration.delegateRemoteModel.name,
                role: .codingWorker
            ),
            activityChanged: events.agentActivityChanged
        )
    }

    private static func toolContext(
        for configuration: ModelSessionConfiguration,
        repositoryMap: RemoteRepositoryMapCapability?
    ) -> ToolAccessContext {
        ToolAccessContext(
            hasWorkspace: !configuration.workspaceRoot.isEmpty,
            hasSkills: !configuration.availableSkills.isEmpty,
            hasDelegateModel: configuration.delegateRemoteModel.enabled,
            repositoryMapDetail: repositoryMap?.detail
        )
    }

    private static func preferredToolTier(
        backend: ModelBackend,
        remoteModel: RemoteModelConfig?
    ) -> ModelToolTier {
        if backend == .foundationApple { return .onDevice }
        // Codex receives TurboCode tools through App Server dynamic tools and
        // must never receive a duplicate FoundationModels session surface.
        if backend == .codex { return .none }
        return remoteModel?.repositoryMap == .enhanced ? .enhanced : .standard
    }

    private static func activeModel(
        for configuration: ModelSessionConfiguration
    ) -> any LanguageModel {
        switch configuration.backend {
        case .foundationApple:
            SystemLanguageModel.default
        case .foundationServe, .llamaServer, .premium:
            providerModel(
                for: configuration.activeRemoteModel ?? RemoteModelConfig.fallbackLlama
            )
        case .codex:
            // ChatStore dispatches Codex turns before this placeholder session
            // is used. A concrete model is still required by the factory type.
            SystemLanguageModel.default
        }
    }

    private static func providerModel(for model: RemoteModelConfig) -> ProviderLanguageModel {
        ProviderLanguageModel(
            configuration: model,
            credential: model.credential
        )
    }

    private static func backend(for role: RemoteModelRole) -> ModelBackend {
        switch role {
        case .local: .llamaServer
        case .pcc: .foundationServe
        case .premium: .premium
        }
    }

    private static func systemPrompt(
        for configuration: ModelSessionConfiguration,
        role: TurboCodeSystemPromptRole,
        backend: ModelBackend,
        plan: ModelToolPlan?
    ) -> String {
        // Consume the resolved plan rather than the requested profile so the
        // prompt never advertises a capability rejected by the model's tier.
        let toolIDs = plan?.assignments
            .filter(\.isRegistered)
            .map(\.id) ?? []
        return TurboCodeSystemPromptBuilder.build(
            TurboCodeSystemPromptContext(
                role: role,
                backend: backend,
                workspaceRoot: configuration.workspaceRoot,
                agentTuning: configuration.agentTuning,
                toolIDs: toolIDs,
                toolNames: toolIDs.map(\.rawValue),
                availableSkills: configuration.availableSkills,
                workspaceInstructions: configuration.workspaceInstructions
            )
        )
    }
}
