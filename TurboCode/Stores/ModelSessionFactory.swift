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
    let reasoningLevel: ContextOptions.ReasoningLevel?

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
        }
        .model(model)
        .temperature(temperature)
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
        let instructions = instructions(for: configuration)
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

        if configuration.orchestratorMode == .orchestrator,
           activeCapabilities.toolAccess != .none {
            return makeOrchestratorSession(
                configuration: configuration,
                instructions: instructions,
                activeModel: activeModel,
                activeCapabilities: activeCapabilities,
                history: history,
                events: events
            )
        }

        guard activeCapabilities.toolAccess != .none else {
            return makeToollessSession(
                instructions: instructions,
                model: activeModel,
                temperature: configuration.activeTemperature,
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

        return LanguageModelSession(
            profile: StandaloneProfile(
                instructions: instructions,
                activations: configuration.skillActivations,
                diskSkills: configuration.availableSkills,
                workspaceRoot: configuration.workspaceRoot,
                model: activeModel,
                temperature: configuration.activeTemperature,
                reasoningLevel: activeCapabilities.reasoningLevel,
                dropsCompletedToolCalls: configuration.dropsCompletedToolCalls,
                executionPolicy: configuration.agentTuning.execution,
                gitPolicy: configuration.agentTuning.git,
                toolPlan: standalonePlan,
                supplementalTools: toolInstances(
                    for: standalonePlan,
                    configuration: configuration,
                    including: [
                        .turboCodeGuide,
                        .listWorkspace,
                        .swiftWorkspaceMap,
                        .xcodeProject,
                        .writeOnDevice
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

    private static func makeOrchestratorSession(
        configuration: ModelSessionConfiguration,
        instructions: String,
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
        let powerfulTool = CallPowerfulModelTool(
            model: delegateModel,
            temperature: configuration.delegateTemperature,
            reasoningLevel: delegateCapabilities.reasoningLevel,
            delegateTools: toolInstances(
                for: delegatePlan,
                configuration: configuration,
                repositoryMapContextTokens: configuration.delegateRemoteModel.contextWindowTokens
            ),
            delegateInstructions: instructions,
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

        return LanguageModelSession(
            profile: TurboCodeDynamicProfile(
                instructions: orchestratorInstructions(
                    base: instructions,
                    workspaceRoot: configuration.workspaceRoot
                ),
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
        reasoningLevel: ContextOptions.ReasoningLevel?,
        history: [Transcript.Entry]
    ) -> LanguageModelSession {
        LanguageModelSession(
            profile: ToollessProfile(
                instructions: instructions,
                model: model,
                temperature: temperature,
                reasoningLevel: reasoningLevel
            ),
            history: history
        )
    }

    private static func toolInstances(
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
                return ListWorkspaceTool(workspaceRoot: configuration.workspaceRoot)
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

    private static func instructions(for configuration: ModelSessionConfiguration) -> String {
        var text = """
        You are TurboCode, an AI coding assistant developed by the TurboCode team.
        You are NOT Apple's built-in assistant. Never refer to yourself as an Apple
        model or any Apple product. Your name is TurboCode.
        """
        text += "\nAlways use Markdown formatting in your responses: **bold**, `code`, ```code blocks```, tables, etc."
        text += "\nStructured tool results with a native TurboCode presentation are already visible to the user. Do not repeat, enumerate, or tabulate their contents in the assistant response. Add only a brief contextual sentence when useful, unless the user explicitly requests analysis of the result."
        text += "\nCall turbocode_guide only when the user explicitly asks about the TurboCode product itself, asks what you or the app can do, or requests help with TurboCode capabilities, workflows, models, tools, safety, settings, or best use. Do not call it for greetings, casual conversation, ordinary coding questions, or questions about the user's project. A mere mention of TurboCode is not enough. Pass the user's original question as query, base product facts on the returned official documentation, and answer in the user's language."
        switch configuration.agentTuning.agent.responseStyle {
        case .concise:
            text += "\nKeep responses concise and lead with the result. Include only details needed to act or verify."
        case .balanced:
            text += "\nKeep responses focused, with enough implementation and verification detail to be useful."
        case .detailed:
            text += "\nExplain decisions and verification in detail while avoiding repetition."
        }
        if configuration.agentTuning.agent.verifiesChanges {
            text += "\nAfter changing source code, run the most focused available build or test that verifies the change."
        }
        if !configuration.availableSkills.isEmpty {
            let catalog = configuration.availableSkills
                .map { "- \($0.name): \($0.description)" }
                .joined(separator: "\n")
            text += """

            TurboCode discovers reusable skills automatically from ~/.turbocode/SKILLS/**/SKILL.md.
            Available skills:
            \(catalog)
            Use load_skill when a matching description applies; do not ask permission or announce loading.
            """
        }
        text += "\nTreat /skill <name> and /<skill-name> as explicit requests to activate that skill before handling the remaining prompt. Treat /skills as a request to list the currently advertised skills with concise descriptions."
        if !configuration.workspaceRoot.isEmpty {
            text += "\nThe current workspace is at: \(configuration.workspaceRoot)"
            text += "\nActivate the appropriate skill below to access file and code tools."
            text += "\nAll file operations are restricted to the workspace directory."
            text += "\nNEVER access files outside the workspace."
            text += "\nUse read_file with startLine and endLine to inspect only the relevant numbered source range and preserve context."
            text += "\nUse list_workspace whenever you need to list or visually inspect the files and folders in one workspace directory. Pass a workspace-relative path and use . for the root."
            text += "\nUse git for every Git operation, including the init operation when the workspace is not yet a repository. Git mutations are supported directly; never claim they are blocked by the bash sandbox. Use xcode_project for Xcode discovery, builds, and tests whenever it is available. Use bash for Swift Package commands, other builds and tests, and precise non-Git inspection. Bash can read the workspace but cannot write to it."
            text += "\nUse edit_file for every source or text-file creation and modification. Read the relevant range immediately before editing, copy its Revision, and request one contiguous change per call. Never generate unified diff hunks."
            text += "\nWhen writing articles, biographies, documentation, or other long-form prose, preserve readable paragraphs with a blank line between them. The tool content must contain real newline characters; never collapse the whole document into one long line."
            text += "\nFile and directory deletion and destructive Git operations require approval. If a tool output contains TURBOCODE_APPROVAL_REQUIRED, stop and wait for the user. Never print that technical approval block in your response."
        }
        return text
    }

    private static func orchestratorInstructions(base: String, workspaceRoot: String) -> String {
        base + """


        === ORCHESTRATOR MODE ===
        You are TurboCode Orchestrator. You are NOT an Apple model — you are part of the TurboCode app. Your name is TurboCode, and you delegate complex tasks to the powerful coding model via `call_powerful_model`. Use `list_workspace` to list directories for the user. Use `file_system` only for metadata, file discovery, and supported filesystem operations.

        For explicit questions about the TurboCode product itself, use `turbocode_guide` directly and answer from the returned official documentation. Never use it for greetings or ordinary coding questions. For EVERYTHING else — reading files, writing or editing files, generating code, git operations, grep/searching, complex analysis, or any multi-step task — you MUST use `call_powerful_model` to delegate to the powerful coding model. The powerful model has all the tools it needs (read_file, grep, git, bash, file_system, and edit_file).

        CRITICAL — Never trust your own knowledge:
        - If you need to answer with file contents, always delegate reading to `call_powerful_model`.
        - If you need to modify code, always delegate to `call_powerful_model`.
        - Never rely on your training data for what a file contains or what code looks like in this project.
        - Always use the tools — `list_workspace` for directory listings, `call_powerful_model` for actual file work.

        Your role is:
        1. Understand what the user wants.
        2. For TurboCode product guidance: use `turbocode_guide` directly.
        3. For directory listings: use `list_workspace` directly. For metadata or file discovery: use `file_system` directly.
        4. For everything else: first output a brief acknowledgment to the user, then call `call_powerful_model` with a complete, self-contained task description that includes all relevant context (file paths, code snippets, error messages, requirements). Include full paths so the powerful model can navigate the workspace at: \(workspaceRoot).
        5. Synthesise the powerful model's response into a clear, well-formatted answer for the user.

        === APPROVAL REQUESTS ===
        If the powerful model's response contains "TURBOCODE_APPROVAL_REQUIRED", stop and wait for the user. The app presents the approval UI; never expose the technical approval block in your response.
        """
    }
}
