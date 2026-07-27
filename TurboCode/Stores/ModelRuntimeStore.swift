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
    private(set) var remoteModels: [RemoteModelConfig] = RemoteModelConfig.defaults
    private(set) var activeRemoteModelID: String
    private(set) var dynamicProfiles: [UserDynamicProfile]
    private(set) var activeDynamicProfileID: UUID?
    private(set) var availableSkills: [TurboCodeSkillDefinition] = []

    var composerModel: String
    var activeBackend: ModelBackend
    var orchestratorMode: OrchestratorMode
    let skillActivations = SkillActivations()
    private(set) var session: LanguageModelSession

    var activeDynamicProfile: UserDynamicProfile? {
        activeDynamicProfileID.flatMap { id in
            dynamicProfiles.first(where: { $0.id == id })
        }
    }

    var activeBaseModelID: ProfileBaseModelID {
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
        let initialRemote = RemoteModelConfig.defaults.first {
            $0.id == selectedID && Self.hasCredential(for: $0)
        } ?? RemoteModelConfig.fallbackLlama
        let restoredProfile = savedProfile.flatMap { profile in
            if profile.baseModelID == .onDevice { return profile }
            return profile.baseModelID.remoteModelID == initialRemote.id
                ? profile
                : nil
        }

        activeRemoteModelID = initialRemote.id
        dynamicProfiles = loadedProfiles
        activeDynamicProfileID = mode == .standalone
            ? restoredProfile?.id
            : nil
        activeBackend =
            mode == .orchestrator || restoredProfile?.baseModelID == .onDevice
            ? .foundationApple
            : Self.backend(for: initialRemote.role)
        orchestratorMode = mode
        composerModel = mode == .orchestrator
            ? "Apple · Orchestrator"
            : (restoredProfile?.name ?? initialRemote.name)

        let initialModel: any LanguageModel =
            mode == .orchestrator || restoredProfile?.baseModelID == .onDevice
            ? SystemLanguageModel.default
            : ProviderLanguageModel(
                configuration: initialRemote,
                apiKey: initialRemote.credential.flatMap(
                    CredentialStore.value(for:)
                )
            )
        session = LanguageModelSession(model: initialModel)

        if savedProfile != nil, restoredProfile == nil {
            UserDefaults.standard.removeObject(
                forKey: "activeDynamicProfileID"
            )
        }
    }

    func applyOnboarding(tuning: AgentTuningConfig) {
        agentTuning = tuning
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

    func selectCodex(displayName: String) {
        clearDynamicProfileSelection()
        activeBackend = .codex
        composerModel = "Codex · \(displayName)"
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
        let selected = loaded.first(where: {
            $0.id == activeRemoteModelID && $0.enabled && isConfigured($0)
        }) ?? loaded.first(where: {
            $0.enabled && $0.role == .local && isConfigured($0)
        }) ?? loaded.first(where: {
            $0.enabled && isConfigured($0)
        })
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

    func refreshSkills(force: Bool = false) -> Bool {
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

    func languageModel(
        for model: RemoteModelConfig
    ) -> ProviderLanguageModel {
        ProviderLanguageModel(
            configuration: model,
            apiKey: model.credential.flatMap(CredentialStore.value(for:))
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
        if discardingCapabilityContext {
            for name in skillActivations.activeSkillNames {
                skillActivations.deactivate(name)
            }
        }
        let delegateModel = delegateRemoteModel
        let sessionSkills = DynamicProfileRuntimeSelection.skills(
            from: availableSkills,
            profile: activeDynamicProfile
        )
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
                skillActivations: skillActivations,
                reasoningLevel: reasoningLevel,
                delegateReasoningLevel: reasoningLevel(for: delegateModel),
                activeTemperature: temperature(for: activeRemoteModel),
                delegateTemperature: temperature(for: delegateModel),
                dropsCompletedToolCalls: shouldDropCompletedToolCalls
            ),
            history: history,
            events: events
        )
    }

    private func configuredSkills() -> [TurboCodeSkillDefinition] {
        let discovered = TurboCodeConfig.shared.loadSkills()
        guard !agentTuning.skills.discoversUserSkills else {
            return discovered
        }
        let builtInNames: Set<String> = ["turbocode", "skill-creator"]
        return discovered.filter { builtInNames.contains($0.name) }
    }

    private static func hasCredential(for model: RemoteModelConfig) -> Bool {
        guard let credential = model.credential else { return true }
        return !(CredentialStore.value(for: credential) ?? "").isEmpty
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
        remoteModels.first(where: {
            $0.id == agentTuning.orchestrator.delegateModelID
                && $0.enabled && isConfigured($0)
        }) ?? remoteModels.first(where: {
            $0.enabled && $0.role == .local && isConfigured($0)
        }) ?? activeRemoteModel.flatMap {
            $0.enabled && isConfigured($0) ? $0 : nil
        } ?? remoteModels.first(where: {
            $0.enabled && isConfigured($0)
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
        guard activeBackend != .foundationApple else { return true }
        return activeRemoteModel?.reasoningTransport != .deepseekThinking
    }
}
