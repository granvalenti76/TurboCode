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
    let dropsCompletedToolCalls: Bool
    let workspaceInstructions: WorkspaceInstructions?
}

struct ModelSessionEvents {
    let toolStarted: @Sendable (Transcript.ToolCall, ModelBackend) async -> Void
    let toolFinished: @Sendable (Transcript.ToolCall, Transcript.ToolOutput, ModelBackend) async -> Void
    let delegationChanged: @Sendable (Bool) async -> Void
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

        if configuration.orchestratorMode == .orchestrator,
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
                    role: .standalone,
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
            profile: .standalone,
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
            role: .standalone,
            backend: configuration.backend,
            plan: standalonePlan
        )

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
                supplementalTools: toolInstances(
                    for: standalonePlan,
                    configuration: configuration,
                    including: usesExclusiveToolSelection ? nil : [
                            .turboCodeGuide,
                            .listWorkspace,
                            .swiftWorkspaceMap,
                            .xcodeProject,
                            .writeOnDevice,
                            .removeFile
                        ],
                    repositoryMapContextTokens: activeRemoteConfiguration?.contextWindowTokens
                        ?? 32_768
                ),
                onToolStart: { call in
                    await events.toolStarted(call, configuration.backend)
                },
                onToolEnd: { call, output in
                    await events.toolFinished(call, output, configuration.backend)
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
                await events.toolStarted(call, delegateBackend)
            },
            onToolEnd: { call, output in
                await events.toolFinished(call, output, delegateBackend)
            }
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
                    await events.toolStarted(call, .foundationApple)
                },
                onToolEnd: { call, output in
                    await events.toolFinished(call, output, .foundationApple)
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
            case .swiftPackageInit:
                return SwiftPackageInitTool(workspaceRoot: configuration.workspaceRoot)
            case .xcodeProject:
                return XcodeProjectTool(
                    workspaceRoot: configuration.workspaceRoot,
                    executionPolicy: configuration.agentTuning.execution,
                    enhancedOutput: plan.tier == .enhanced
                )
            case .editFile:
                return EditFileTool(workspaceRoot: configuration.workspaceRoot)
            case .writeOnDevice:
                return WriteOnDeviceTool(workspaceRoot: configuration.workspaceRoot)
            case .removeFile:
                return RemoveFileTool(workspaceRoot: configuration.workspaceRoot)
            case .loadSkill:
                guard !configuration.availableSkills.isEmpty else { return nil }
                return LoadSkillTool(skills: configuration.availableSkills)
            case .callPowerfulModel:
                return nil
            }
        }
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
            apiKey: model.credential.flatMap(CredentialStore.value(for:))
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
