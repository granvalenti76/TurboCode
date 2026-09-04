import Foundation
import Observation

nonisolated enum ProfileLibrarySelection: Hashable, Sendable {
    case builtIn(ProfileBaseModelID)
    case custom(UUID)
}

/// Stable selection identity for the profile editor's agent hierarchy.
/// The first UI slice mirrors the runtime truth: one primary agent and at most
/// one delegated worker, while leaving the outline extensible for 0.5.
nonisolated enum ProfileAgentNodeID: String, Hashable, Sendable {
    case primary
    case worker
}

nonisolated struct ProfileAgentNode: Identifiable, Hashable, Sendable {
    let id: ProfileAgentNodeID
    let title: String
    let subtitle: String
    let systemImage: String
    let depth: Int
}

nonisolated struct ProfileModelOption: Identifiable, Hashable, Sendable {
    let id: ProfileBaseModelID
    let subtitle: String
    let tier: ModelToolTier
    let defaultToolIDs: Set<ToolCapabilityID>
    let compatibleToolIDs: Set<ToolCapabilityID>
    let isAvailable: Bool
}

@MainActor
@Observable
final class SkillsViewModel {
    private let store: DynamicProfileStore
    private(set) var profiles: [UserDynamicProfile] = []
    private(set) var installedSkills: [TurboCodeSkillDefinition] = []
    /// Profile editing only needs validated metadata; process activation stays
    /// owned by the runtime and is intentionally not mirrored in ChatStore.
    private(set) var discoveredTypeScriptPlugins: [TypeScriptPluginDescriptor] = []
    private(set) var baseline: UserDynamicProfile?
    var draft: UserDynamicProfile?
    var selection: ProfileLibrarySelection = .builtIn(.onDevice)
    var capabilitySearch = ""
    var errorMessage: String?

    init(store: DynamicProfileStore = .live) {
        self.store = store
    }

    var isDirty: Bool { draft != baseline }
    var canSave: Bool { draft != nil && isDirty }

    func reload() {
        do {
            profiles = try store.load()
            installedSkills = TurboCodeConfig.shared.loadSkills()
            let pluginDiscovery = TypeScriptPluginRegistry.live().discover()
            TypeScriptPluginRuntimeStore.shared.recordDiscovery(pluginDiscovery)
            discoveredTypeScriptPlugins = pluginDiscovery.plugins
            errorMessage = nil
            if case .custom(let id) = selection {
                selectCustom(id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ value: ProfileLibrarySelection) {
        selection = value
        switch value {
        case .builtIn:
            draft = nil
            baseline = nil
        case .custom(let id):
            selectCustom(id)
        }
    }

    func create(
        name: String,
        summary: String,
        baseModelID: ProfileBaseModelID,
        workerModelID: String? = nil,
        codexModelID: String? = nil,
        codexReasoningEffort: CodexReasoningEffort? = nil,
        includeDelegation: Bool = false,
        copyDefaults: Bool,
        settings: SettingsStore
    ) -> Bool {
        // Resolve defaults from the selected model. Delegation is a capability
        // choice, not a parallel execution role, and is added only when the
        // user explicitly enables `delegate_task` in the creation flow.
        let effectiveBaseModelID = baseModelID
        let option = modelOption(for: effectiveBaseModelID, settings: settings)
        let toolIDs = copyDefaults
            ? option.defaultToolIDs.subtracting([.loadSkill]).map(\.rawValue).sorted()
            : []
        let skillIDs = copyDefaults ? installedSkills.map(\.name) : []
        do {
            var profile = UserDynamicProfile(
                name: name,
                summary: summary,
                baseModelID: effectiveBaseModelID,
                workerModelID: workerModelID,
                codexModelID: codexModelID,
                codexReasoningEffort: codexReasoningEffort,
                toolIDs: toolIDs,
                skillIDs: skillIDs
            )
            if includeDelegation {
                profile.setExecutionRole(.coordinatorWorker)
            }
            profile = try profile.validated()
            try ensureUniqueName(profile.name, excluding: nil)
            profiles.append(profile)
            try persist()
            select(.custom(profile.id))
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        guard var value = draft else { return false }
        do {
            value = try value.validated()
            try ensureUniqueName(value.name, excluding: value.id)
            value.updatedAt = .now
            guard let index = profiles.firstIndex(where: { $0.id == value.id }) else {
                throw UserDynamicProfileError.profileNotFound
            }
            profiles[index] = value
            try persist()
            draft = value
            baseline = value
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteSelected() {
        guard let draft else { return }
        profiles.removeAll { $0.id == draft.id }
        do {
            try persist()
            select(.builtIn(draft.baseModelID))
        } catch {
            errorMessage = error.localizedDescription
            reload()
        }
    }

    func discardChanges() {
        draft = baseline
    }

    func updateDraft(_ mutation: (inout UserDynamicProfile) -> Void) {
        guard var value = draft else { return }
        mutation(&value)
        draft = value
    }

    func containsTool(_ id: ToolCapabilityID) -> Bool {
        draft?.toolIDs.contains(id.rawValue) == true
    }

    func setTool(_ id: ToolCapabilityID, included: Bool) {
        updateDraft { value in
            if id == .delegateTask {
                // The capability itself is the orchestration switch. Keep the
                // selected worker ready for progressive disclosure without
                // introducing a second persisted execution mode.
                if included {
                    if !ProfileBaseModelID.delegationCases.contains(value.baseModelID) {
                        value.baseModelID = .deepseek
                    }
                    // The editor disables greedy mode for delegated profiles,
                    // but this mutation must also repair a draft that already
                    // contains the incompatible combination.
                    value.greedyMode = false
                    if !ProfileBaseModelID.workerCases.contains(where: {
                        $0.rawValue == (value.workerModelID ?? "")
                    }) {
                        value.workerModelID = ProfileBaseModelID.llama.rawValue
                    }
                    if !value.toolIDs.contains(id.rawValue) {
                        value.toolIDs.append(id.rawValue)
                    }
                } else {
                    value.toolIDs.removeAll { $0 == id.rawValue }
                }
                return
            }
            if included, !value.toolIDs.contains(id.rawValue) {
                value.toolIDs.append(id.rawValue)
            } else if !included {
                value.toolIDs.removeAll { $0 == id.rawValue }
            }
        }
    }

    /// Projects the persisted profile into the hierarchy rendered by the
    /// editor. No extra subagent is advertised until the runtime can execute
    /// it; enabling delegation creates the single worker already supported.
    func agentNodes(
        for profile: UserDynamicProfile,
        fallbackWorkerID: String
    ) -> [ProfileAgentNode] {
        var nodes = [
            ProfileAgentNode(
                id: .primary,
                title: profile.name,
                subtitle: "\(profile.usesDelegation ? "Coordinator" : "Agent") · \(profile.baseModelID.displayName)",
                systemImage: "person.crop.rectangle.stack",
                depth: 0
            )
        ]
        guard profile.usesDelegation else { return nodes }
        let workerID = profile.resolvedWorkerModelID(
            fallback: fallbackWorkerID
        )
        let workerName = ProfileBaseModelID(rawValue: workerID)?.displayName
            ?? workerID
        nodes.append(
            ProfileAgentNode(
                id: .worker,
                title: "Delegated Worker",
                subtitle: "Subagent · \(workerName)",
                systemImage: "hammer",
                depth: 1
            )
        )
        return nodes
    }

    func containsSkill(_ name: String) -> Bool {
        draft?.skillIDs.contains(name) == true
    }

    func setSkill(_ name: String, included: Bool) {
        updateDraft { value in
            if included, !value.skillIDs.contains(name) {
                value.skillIDs.append(name)
            } else if !included {
                value.skillIDs.removeAll { $0 == name }
            }
        }
    }

    func modelOptions(settings: SettingsStore) -> [ProfileModelOption] {
        ProfileBaseModelID.builtInCases.map {
            modelOption(for: $0, settings: settings)
        }
    }

    /// All models that can be selected by a custom profile. Codex is omitted
    /// from the built-in library but remains available here for profiles that
    /// opt into Delegate Task and its App Server settings.
    func profileModelOptions(settings: SettingsStore) -> [ProfileModelOption] {
        ProfileBaseModelID.profileCases.map {
            modelOption(for: $0, settings: settings)
        }
    }

    func delegationOptions(settings: SettingsStore) -> [ProfileModelOption] {
        ProfileBaseModelID.delegationCases.map {
            modelOption(for: $0, settings: settings)
        }
    }

    /// Compatibility alias for older callers of the profile editor.
    func coordinatorOptions(settings: SettingsStore) -> [ProfileModelOption] {
        delegationOptions(settings: settings)
    }

    func workerOptions(settings: SettingsStore) -> [ProfileModelOption] {
        ProfileBaseModelID.workerCases.map {
            modelOption(for: $0, settings: settings)
        }
    }

    /// Returns the complete tool catalog the selected worker can support. The
    /// profile editor uses this for an explicit worker allowlist while runtime
    /// construction applies the saved selection itself.
    func workerToolPlan(
        workerModelID: String,
        settings: SettingsStore
    ) -> ModelToolPlan? {
        guard let workerID = ProfileBaseModelID(rawValue: workerModelID),
              ProfileBaseModelID.workerCases.contains(workerID) else {
            return nil
        }
        let option = modelOption(for: workerID, settings: settings)
        let remote = workerID.remoteModelID.flatMap { remoteID in
            settings.remoteModels.first(where: { $0.id == remoteID })
                ?? RemoteModelConfig.defaults.first(where: { $0.id == remoteID })
        }
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: true,
            hasDelegateModel: true,
            repositoryMapDetail: remote?.repositoryMap.detail
        )
        return ModelToolCatalog.plan(
            profile: .delegate,
            tier: option.tier,
            context: context
        )
    }

    func modelOption(for id: ProfileBaseModelID, settings: SettingsStore) -> ProfileModelOption {
        let remote = id.remoteModelID.flatMap { remoteID in
            settings.remoteModels.first(where: { $0.id == remoteID })
                ?? RemoteModelConfig.defaults.first(where: { $0.id == remoteID })
        }
        let tier: ModelToolTier = id == .onDevice
            ? .onDevice
            : (remote?.repositoryMap == .enhanced ? .enhanced : .standard)
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: true,
            hasDelegateModel: true,
            repositoryMapDetail: remote?.repositoryMap.detail
        )
        let defaults = ModelToolCatalog.plan(profile: .standalone, tier: tier, context: context).registeredIDs
        var compatible = ModelToolCatalog.plan(
            profile: .standalone,
            tier: tier,
            context: context,
            selectedIDs: Set(ToolCapabilityID.allCases)
        ).registeredIDs
        compatible.remove(.callPowerfulModel)
        compatible.remove(.loadSkill)
        if !ProfileBaseModelID.delegationCases.contains(id) {
            // Only models in delegationCases expose structured delegate_task
            // for custom profiles; the built-in on-device profile remains
            // direct because it has no explicit capability selection.
            compatible.remove(.delegateTask)
        }
        let subtitle: String
        switch id {
        case .onDevice: subtitle = "Private and optimized for compact tool schemas"
        case .llama: subtitle = "Local OpenAI-compatible model"
        // PCC-RETIREMENT: remove the legacy model case with the profile enum.
        case .pcc: subtitle = "Private Cloud Compute"
        case .deepseek: subtitle = "Enhanced coding model"
        case .codex: subtitle = "Codex App Server with ChatGPT"
        }
        return ProfileModelOption(
            id: id,
            subtitle: subtitle,
            tier: tier,
            defaultToolIDs: defaults,
            compatibleToolIDs: compatible,
            // Authentication remains a visible runtime state for Codex, so its
            // coordinator option must stay selectable before ChatGPT sign-in.
            isAvailable: id == .onDevice
                || id == .codex
                || (remote?.enabled == true && isConfigured(remote))
        )
    }

    private func selectCustom(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            selection = .builtIn(.onDevice)
            draft = nil
            baseline = nil
            return
        }
        draft = profile
        baseline = profile
    }

    private func persist() throws {
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try store.save(profiles)
    }

    private func ensureUniqueName(_ name: String, excluding id: UUID?) throws {
        if profiles.contains(where: {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            throw UserDynamicProfileError.duplicateName(name)
        }
    }

    private func isConfigured(_ model: RemoteModelConfig?) -> Bool {
        guard let model else { return false }
        guard let credential = model.credential else { return true }
        return CredentialStore.contains(account: credential)
    }
}
