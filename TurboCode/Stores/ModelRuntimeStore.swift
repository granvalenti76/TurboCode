import Foundation
import FoundationModels
import FoundationModelsUtilities
import Observation

/// Owns FoundationModels profile selection and session construction.
///
/// This store is the single boundary for configured models, dynamic profiles,
/// skills, sampling options, and transcript-preserving session rebuilds. Codex
/// process lifecycle and chat presentation intentionally live elsewhere.
@MainActor
@Observable
final class ModelRuntimeStore {
    private(set) var agentTuning: AgentTuningConfig = .default
    private(set) var remoteModels: [RemoteModelConfig]
    private(set) var activeRemoteModelID: String
    private(set) var dynamicProfiles: [UserDynamicProfile]
    private(set) var activeDynamicProfileID: UUID?
    private(set) var availableSkills: [TurboCodeSkillDefinition] = []
    private var workspaceInstructionsRevision: String?

    var composerModel: String
    var activeBackend: ModelBackend
    var orchestratorMode: OrchestratorMode
    private(set) var session: LanguageModelSession
    private var skillsWorkspaceRoot: String?
    /// Lives for the active session and is installed for one request at a time.
    /// Rebuilding a session replaces this actor so an older response keeps its
    /// own transport boundary while the new session starts cleanly.
    private var reasoningStreamRelay: ReasoningStreamRelay

    var activeReasoningStreamRelay: ReasoningStreamRelay? {
        activeBackend == .llamaServer ? reasoningStreamRelay : nil
    }

    /// Read-only transcript projection for persistence and context helpers.
    /// Session construction and replacement remain owned by this store; UI
    /// facades should not retain or pass the concrete session object around.
    var transcript: Transcript {
        session.transcript
    }

    var activeDynamicProfile: UserDynamicProfile? {
        activeDynamicProfileID.flatMap { id in
            dynamicProfiles.first(where: { $0.id == id })
        }
    }

    var activeBaseModelID: ProfileBaseModelID {
        if activeBackend == .codex { return .codex }
        if activeBackend == .foundationApple { return .onDevice }
        return ProfileBaseModelID(rawValue: activeRemoteModelID) ?? .llama
    }

    var activeRemoteModel: RemoteModelConfig? {
        remoteModels.first(where: { $0.id == activeRemoteModelID })
    }

    var enabledRemoteModels: [RemoteModelConfig] {
        remoteModels.filter(\.enabled)
    }

    var activeModelSupportsReasoning: Bool {
        activeBackend == .codex
            || (
                activeBackend != .foundationApple
                    && (activeRemoteModel?.supportsReasoning ?? false)
            )
    }

    var reasoningLevel: ContextOptions.ReasoningLevel? {
        guard activeBackend != .foundationApple,
              activeBackend != .codex else { return nil }
        return reasoningLevel(for: activeRemoteModel)
    }

    var persistedModelIdentifier: String {
        if let activeDynamicProfileID {
            return "profile:\(activeDynamicProfileID.uuidString)"
        }
        if activeBackend == .codex {
            return ModelBackend.codex.rawValue
        }
        return activeBackend == .foundationApple
            ? activeBackend.rawValue
            : activeRemoteModelID
    }

    init() {
        let loadedProfiles = (try? DynamicProfileStore.live.load()) ?? []
        let configuredRemoteModels = (try? TurboCodeConfig.shared.loadRemoteModels())
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? RemoteModelConfig.defaults
        let savedProfileID = UserDefaults.standard.string(
            forKey: "activeDynamicProfileID"
        ).flatMap(UUID.init(uuidString:))
        let savedProfile = loadedProfiles.first {
            $0.id == savedProfileID
        }
        let savedMode = UserDefaults.standard.string(forKey: "orchestratorMode")
            ?? OrchestratorMode.standalone.rawValue
        let mode = OrchestratorMode(rawValue: savedMode) ?? .standalone
        let selectedID = savedProfile?.baseModelID.remoteModelID
            ?? UserDefaults.standard.string(forKey: "activeRemoteModelID")
            ?? "llama"
        // Restore the selected provider from configuration only. Credential
        // availability is checked when the user selects the model or sends a
        // request, never while the application is bootstrapping.
        let initialRemote = Self.initialRemoteModel(
            from: configuredRemoteModels,
            selectedID: selectedID
        )
        let restoredProfile = savedProfile.flatMap { profile in
            if profile.baseModelID == .codex { return profile }
            if profile.baseModelID == .onDevice { return profile }
            return profile.baseModelID.remoteModelID == initialRemote.id
                ? profile
                : nil
        }

        let reasoningStreamRelay = ReasoningStreamRelay()
        self.reasoningStreamRelay = reasoningStreamRelay

        remoteModels = configuredRemoteModels
        activeRemoteModelID = initialRemote.id
        dynamicProfiles = loadedProfiles
        activeDynamicProfileID = mode == .standalone
            ? restoredProfile?.id
            : nil
        let initialBackend: ModelBackend = restoredProfile?.baseModelID == .codex
            ? .codex
            : mode == .orchestrator || restoredProfile?.baseModelID == .onDevice
            ? .foundationApple
            : Self.backend(for: initialRemote.role)
        activeBackend = initialBackend
        orchestratorMode = mode
        composerModel = mode == .orchestrator
            ? "Apple · Orchestrator"
            : (restoredProfile?.name ?? initialRemote.name)

        let initialModel: any LanguageModel =
            mode == .orchestrator || restoredProfile?.baseModelID == .onDevice
            ? SystemLanguageModel.default
            : ProviderLanguageModel(
                configuration: initialRemote,
                credential: initialRemote.credential,
                reasoningStreamRelay: initialBackend == .llamaServer
                    ? reasoningStreamRelay
                    : nil
            )
        session = LanguageModelSession(model: initialModel)

        if savedProfile != nil, restoredProfile == nil {
            UserDefaults.standard.removeObject(
                forKey: "activeDynamicProfileID"
            )
        }
    }

    /// Selects the first session model from persisted configuration before a
    /// `LanguageModelSession` is created. This prevents startup from briefly
    /// binding Llama to the built-in localhost fallback when `models.json`
    /// points at another server.
    nonisolated static func initialRemoteModel(
        from models: [RemoteModelConfig],
        selectedID: String
    ) -> RemoteModelConfig {
        models.first(where: { $0.id == selectedID && $0.enabled })
            ?? models.first(where: { $0.enabled && $0.role == .local })
            ?? models.first(where: \.enabled)
            ?? RemoteModelConfig.fallbackLlama
    }

    func applyOnboarding(
        tuning: AgentTuningConfig,
        workspaceRoot: String? = nil
    ) {
        agentTuning = tuning
        skillsWorkspaceRoot = workspaceRoot
        availableSkills = configuredSkills()
    }

    func setOrchestratorMode(_ mode: OrchestratorMode) {
        orchestratorMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "orchestratorMode")
        if mode == .orchestrator {
            activeBackend = .foundationApple
            clearDynamicProfileSelection()
            composerModel = "Apple · Orchestrator"
        } else {
            composerModel = activeBackend.rawValue
        }
    }

    func selectCodex(displayName: String, profileID: UUID? = nil) {
        clearDynamicProfileSelection()
        if let profileID,
           let profile = dynamicProfiles.first(where: {
               $0.id == profileID && $0.baseModelID == .codex
           }) {
            activeDynamicProfileID = profile.id
            UserDefaults.standard.set(
                profile.id.uuidString,
                forKey: "activeDynamicProfileID"
            )
            composerModel = profile.name
        } else {
            composerModel = "Codex · \(displayName)"
        }
        activeBackend = .codex
    }

    @discardableResult
    func selectBackend(_ backend: ModelBackend) -> Bool {
        clearDynamicProfileSelection()
        if backend == .foundationApple {
            activeBackend = .foundationApple
            composerModel = backend.rawValue
            return true
        }
        guard let model = remoteModels.first(where: {
            $0.enabled && isConfigured($0)
                && Self.backend(for: $0.role) == backend
        }) else { return false }
        selectRemoteModel(model)
        return true
    }

    @discardableResult
    func selectRemoteModel(id: String) -> Bool {
        guard let model = remoteModels.first(where: {
            $0.id == id && $0.enabled && isConfigured($0)
        }) else { return false }
        clearDynamicProfileSelection()
        selectRemoteModel(model)
        return true
    }

    @discardableResult
    func selectBuiltInProfile(_ id: ProfileBaseModelID) -> Bool {
        clearDynamicProfileSelection()
        return applyBaseModel(id)
    }

    @discardableResult
    func selectDynamicProfile(_ id: UUID) -> Bool {
        guard let profile = dynamicProfiles.first(where: { $0.id == id }),
              applyBaseModel(profile.baseModelID) else { return false }
        activeDynamicProfileID = profile.id
        UserDefaults.standard.set(
            profile.id.uuidString,
            forKey: "activeDynamicProfileID"
        )
        composerModel = profile.name
        return true
    }

    func reloadDynamicProfiles(selecting id: UUID? = nil) throws -> Bool {
        dynamicProfiles = try DynamicProfileStore.live.load()
        let requestedID = id ?? activeDynamicProfileID
        if let requestedID,
           dynamicProfiles.contains(where: { $0.id == requestedID }) {
            return selectDynamicProfile(requestedID)
        }
        if activeDynamicProfileID != nil {
            clearDynamicProfileSelection()
            composerModel = activeBaseModelID.displayName
            return true
        }
        return false
    }

    func reloadRemoteModels() -> Bool {
        guard let loaded = try? TurboCodeConfig.shared.loadRemoteModels(),
              !loaded.isEmpty else { return false }
        remoteModels = loaded
        // Loading model metadata is safe at startup; credential validation is
        // deliberately deferred to an explicit model selection or request.
        let selected = loaded.first(where: {
            $0.id == activeRemoteModelID && $0.enabled
        }) ?? loaded.first(where: {
            $0.enabled && $0.role == .local
        }) ?? loaded.first(where: { $0.enabled })
        if let selected {
            activeRemoteModelID = selected.id
            if orchestratorMode == .standalone,
               activeBackend != .foundationApple,
               activeBackend != .codex {
                selectRemoteModel(selected)
            }
        }
        if let activeDynamicProfile {
            composerModel = activeDynamicProfile.name
        }
        return true
    }

    func applyAgentTuning(_ value: AgentTuningConfig) -> Bool {
        guard let validated = try? value.validated() else { return false }
        agentTuning = validated
        availableSkills = configuredSkills()
        return true
    }

    func refreshSkills(
        force: Bool = false,
        workspaceRoot: String? = nil
    ) -> Bool {
        if let workspaceRoot {
            skillsWorkspaceRoot = workspaceRoot
        }
        let discovered = configuredSkills()
        guard force || discovered != availableSkills else { return false }
        availableSkills = discovered
        return true
    }

    func resolvedPrompt(for displayText: String) -> String? {
        let trimmed = displayText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed != "/skill" else { return nil }
        guard trimmed.hasPrefix("/") else { return displayText }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        let skillName: String
        let request: String
        if parts.first == "/skill" {
            guard parts.count >= 2 else { return nil }
            skillName = parts[1]
            request = parts.count == 3 ? parts[2] : ""
        } else {
            skillName = String((parts.first ?? "").dropFirst())
            request = parts.count >= 2
                ? parts.dropFirst().joined(separator: " ")
                : ""
        }
        guard let skill = availableSkills.first(where: {
            $0.name == skillName
        }) else { return displayText }
        let userRequest = request.isEmpty
            ? "Apply this skill and respond appropriately to the selected command."
            : request
        return """
        The user explicitly selected the TurboCode skill '\(skill.name)'. Its instructions follow.

        <skill name="\(skill.name)">
        \(skill.prompt)
        </skill>

        User request:
        \(userRequest)
        """
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        UserDefaults.standard.set(effort.rawValue, forKey: "reasoningEffort")
    }

    func isConfigured(_ model: RemoteModelConfig) -> Bool {
        Self.hasCredential(for: model)
    }

    /// Credential checks are reserved for explicit model selection and
    /// provider-management UI; bootstrap paths do not call this helper.
    private static func hasCredential(for model: RemoteModelConfig) -> Bool {
        guard let credential = model.credential else { return true }
        return CredentialStore.contains(account: credential)
    }

    func languageModel(
        for model: RemoteModelConfig
    ) -> ProviderLanguageModel {
        ProviderLanguageModel(
            configuration: model,
            credential: model.credential,
            reasoningStreamRelay: model.id == activeRemoteModelID
                && activeBackend == .llamaServer
                ? reasoningStreamRelay
                : nil
        )
    }

    func rebuildSession(
        workspaceRoot: String,
        keepingHistory: Bool = true,
        discardingCapabilityContext: Bool = false,
        restoringHistory: [Transcript.Entry]? = nil,
        events: ModelSessionEvents
    ) {
        let history = restoringHistory ?? SessionRebuildHistory.prepare(
            session.transcript,
            keepingHistory: keepingHistory,
            discardingCapabilityContext: discardingCapabilityContext
        )
        let workspaceInstructions = WorkspaceInstructionsLoader.load(
            from: workspaceRoot
        )
        workspaceInstructionsRevision = workspaceInstructions?.revision
        let delegateModel = delegateRemoteModel
        let sessionSkills = DynamicProfileRuntimeSelection.skills(
            from: availableSkills,
            profile: activeDynamicProfile,
            safariMCPEnabled: agentTuning.experimental.safariMCPEnabled
        )
        reasoningStreamRelay = ReasoningStreamRelay()
        session = ModelSessionFactory.makeSession(
            configuration: ModelSessionConfiguration(
                backend: activeBackend,
                activeRemoteModel: activeRemoteModel,
                delegateRemoteModel: delegateModel,
                orchestratorMode: orchestratorMode,
                workspaceRoot: workspaceRoot,
                agentTuning: agentTuning,
                availableSkills: sessionSkills,
                activeDynamicProfile: activeDynamicProfile,
                reasoningLevel: reasoningLevel,
                delegateReasoningLevel: reasoningLevel(for: delegateModel),
                activeTemperature: temperature(for: activeRemoteModel),
                delegateTemperature: temperature(for: delegateModel),
                delegateToolIDs: activeDynamicProfile?.resolvedWorkerToolIDs,
                dropsCompletedToolCalls: shouldDropCompletedToolCalls,
                workspaceInstructions: workspaceInstructions,
                reasoningStreamRelay: activeReasoningStreamRelay
            ),
            history: history,
            events: events
        )
    }

    /// Detects instruction edits without rebuilding stable sessions on every turn.
    func workspaceInstructionsChanged(in workspaceRoot: String) -> Bool {
        WorkspaceInstructionsLoader.load(from: workspaceRoot)?.revision
            != workspaceInstructionsRevision
    }

    private func configuredSkills() -> [TurboCodeSkillDefinition] {
        let discovered = TurboCodeConfig.shared.loadSkills(
            workspaceRoot: skillsWorkspaceRoot
        )
        guard !agentTuning.skills.discoversUserSkills else {
            return discovered
        }
        let builtInNames: Set<String> = ["turbocode", "skill-creator"]
        return discovered.filter { builtInNames.contains($0.name) }
    }

    private static func backend(for role: RemoteModelRole) -> ModelBackend {
        switch role {
        case .local: .llamaServer
        case .pcc: .foundationServe
        case .premium: .premium
        }
    }

    private func selectRemoteModel(_ model: RemoteModelConfig) {
        activeRemoteModelID = model.id
        UserDefaults.standard.set(model.id, forKey: "activeRemoteModelID")
        activeBackend = Self.backend(for: model.role)
        composerModel = model.name
    }

    private func applyBaseModel(_ id: ProfileBaseModelID) -> Bool {
        if id == .codex {
            activeBackend = .codex
            composerModel = id.displayName
            return true
        }
        if id == .onDevice {
            activeBackend = .foundationApple
            composerModel = id.displayName
            return true
        }
        guard let remoteID = id.remoteModelID,
              let model = remoteModels.first(where: {
                  $0.id == remoteID && $0.enabled
              }),
              isConfigured(model) else { return false }
        selectRemoteModel(model)
        return true
    }

    private func clearDynamicProfileSelection() {
        activeDynamicProfileID = nil
        UserDefaults.standard.removeObject(forKey: "activeDynamicProfileID")
    }

    private func reasoningLevel(
        for model: RemoteModelConfig?
    ) -> ContextOptions.ReasoningLevel? {
        guard let model, model.supportsReasoning else { return nil }
        let raw = UserDefaults.standard.string(forKey: "reasoningEffort")
            ?? ReasoningEffort.medium.rawValue
        switch ReasoningEffort(rawValue: raw) ?? .medium {
        case .low: return .light
        case .medium: return .moderate
        case .high: return .deep
        }
    }

    private var delegateRemoteModel: RemoteModelConfig {
        let requestedWorkerID = activeDynamicProfile?.resolvedWorkerModelID(
            fallback: agentTuning.orchestrator.delegateModelID
        ) ?? agentTuning.orchestrator.delegateModelID
        return remoteModels.first(where: {
            $0.id == requestedWorkerID
                && $0.enabled
        }) ?? remoteModels.first(where: {
            $0.enabled && $0.role == .local
        }) ?? activeRemoteModel.flatMap {
            $0.enabled ? $0 : nil
        } ?? remoteModels.first(where: {
            $0.enabled
        }) ?? RemoteModelConfig.fallbackLlama
    }

    private func temperature(for model: RemoteModelConfig?) -> Double? {
        guard let model else { return nil }
        if model.reasoningTransport == .deepseekThinking,
           reasoningLevel(for: model) != nil {
            return nil
        }
        return model.temperature
    }

    private var shouldDropCompletedToolCalls: Bool {
        ModelHistoryPolicy.dropsCompletedToolCalls(
            backend: activeBackend,
            reasoningTransport: activeRemoteModel?.reasoningTransport
        )
    }

    /// Creates the same bounded worker adapter used by native coordinators.
    /// Codex depends on this boundary so provider choice, tool policy, verifier,
    /// and Activity events cannot drift between coordinator implementations.
    func makeDelegateInvoker(
        workspaceRoot: String,
        events: ModelSessionEvents
    ) -> ConfiguredAgentTaskInvoker? {
        guard activeDynamicProfile?.usesDelegation == true else {
            return nil
        }
        return ModelSessionFactory.makeDelegateInvoker(
            configuration: sessionConfiguration(workspaceRoot: workspaceRoot),
            events: events
        )
    }

    /// Builds the configured worker for an application-owned task command.
    /// Unlike the model-facing delegate tool, this path is intentionally not
    /// gated by the active profile's capability list: `/task` is an explicit
    /// user action and must remain available when `delegate_task` is hidden.
    func makeIndependentTaskInvoker(
        workspaceRoot: String,
        events: ModelSessionEvents
    ) -> ConfiguredAgentTaskInvoker {
        ModelSessionFactory.makeDelegateInvoker(
            configuration: sessionConfiguration(workspaceRoot: workspaceRoot),
            events: events
        )
    }

    private func sessionConfiguration(
        workspaceRoot: String
    ) -> ModelSessionConfiguration {
        let delegateModel = delegateRemoteModel
        return ModelSessionConfiguration(
            backend: activeBackend,
            activeRemoteModel: activeRemoteModel,
            delegateRemoteModel: delegateModel,
            orchestratorMode: orchestratorMode,
            workspaceRoot: workspaceRoot,
            agentTuning: agentTuning,
            availableSkills: DynamicProfileRuntimeSelection.skills(
                from: availableSkills,
                profile: activeDynamicProfile,
                safariMCPEnabled: agentTuning.experimental.safariMCPEnabled
            ),
            activeDynamicProfile: activeDynamicProfile,
            reasoningLevel: reasoningLevel,
            delegateReasoningLevel: reasoningLevel(for: delegateModel),
            activeTemperature: temperature(for: activeRemoteModel),
            delegateTemperature: temperature(for: delegateModel),
            delegateToolIDs: activeDynamicProfile?.resolvedWorkerToolIDs,
            dropsCompletedToolCalls: shouldDropCompletedToolCalls,
            workspaceInstructions: WorkspaceInstructionsLoader.load(
                from: workspaceRoot
            ),
            reasoningStreamRelay: activeReasoningStreamRelay
        )
    }
}
