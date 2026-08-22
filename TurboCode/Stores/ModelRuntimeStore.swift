import Foundation
import Observation

/// Owns observable model configuration and profile selection.
///
/// This store resolves models, skills, sampling options, and rebuild policy into
/// immutable values. Concrete models, sessions, reasoning relays, and transcript
/// checkpoints belong to the application execution runtime.
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
    private var skillsWorkspaceRoot: String?

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

    /// Captures only the selection needed to build the initial provider
    /// session. `LLMRuntime` consumes this once and creates all concrete
    /// Foundation Models objects behind its execution boundary.
    var foundationModelsBootstrapConfiguration:
        FoundationModelsBootstrapConfiguration {
        FoundationModelsBootstrapConfiguration(
            backend: activeBackend,
            usesSystemModel: activeBackend == .foundationApple,
            remoteModel: activeRemoteModel ?? RemoteModelConfig.fallbackLlama
        )
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

    var reasoningEffort: ReasoningEffort? {
        guard activeBackend != .foundationApple,
              activeBackend != .codex else { return nil }
        return reasoningEffort(for: activeRemoteModel)
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

    /// Produces one immutable configuration snapshot for the execution owner.
    /// Loading workspace instructions here also advances the revision observed
    /// by the configuration facade, but no provider object is built or retained.
    func makeSessionConfiguration(
        workspaceRoot: String
    ) -> ModelSessionConfiguration {
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
        return ModelSessionConfiguration(
            backend: activeBackend,
            activeRemoteModel: activeRemoteModel,
            delegateRemoteModel: delegateModel,
            orchestratorMode: orchestratorMode,
            workspaceRoot: workspaceRoot,
            agentTuning: agentTuning,
            availableSkills: sessionSkills,
            documentationStore: .live,
            activeDynamicProfile: activeDynamicProfile,
            reasoningEffort: reasoningEffort,
            delegateReasoningEffort: reasoningEffort(for: delegateModel),
            activeTemperature: temperature(for: activeRemoteModel),
            delegateTemperature: temperature(for: delegateModel),
            delegateToolIDs: activeDynamicProfile?.resolvedWorkerToolIDs,
            dropsCompletedToolCalls: shouldDropCompletedToolCalls,
            workspaceInstructions: workspaceInstructions
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

    private func reasoningEffort(
        for model: RemoteModelConfig?
    ) -> ReasoningEffort? {
        guard let model, model.supportsReasoning else { return nil }
        let raw = UserDefaults.standard.string(forKey: "reasoningEffort")
            ?? ReasoningEffort.medium.rawValue
        return ReasoningEffort(rawValue: raw) ?? .medium
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
           reasoningEffort(for: model) != nil {
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

}
