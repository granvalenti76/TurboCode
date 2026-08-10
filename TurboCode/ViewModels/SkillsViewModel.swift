import Foundation
import Observation

nonisolated enum ProfileLibrarySelection: Hashable, Sendable {
    case builtIn(ProfileBaseModelID)
    case custom(UUID)
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
        executionRole: ProfileExecutionRole = .direct,
        copyDefaults: Bool,
        settings: SettingsStore
    ) -> Bool {
        // Resolve defaults from the visible coordinator or direct model before
        // the execution role adds its managed delegation capability. Codex
        // route selections stay profile data rather than global settings.
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
            profile.setExecutionRole(executionRole)
            profile = try profile.validated()
            try ensureUniqueName(profile.name, excluding: nil)
            profiles.append(profile)
            try persist()
            select(.custom(profile.id))
            ChatStore.shared?.reloadDynamicProfiles(selecting: profile.id)
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
            ChatStore.shared?.reloadDynamicProfiles()
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
            ChatStore.shared?.reloadDynamicProfiles()
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
                // The capability composer and the Execution picker represent
                // the same typed route. Keep them synchronized so selecting
                // delegation also establishes an explicit worker and removing
                // it cannot leave a coordinator profile without its tool.
                value.setExecutionRole(included ? .coordinatorWorker : .direct)
                return
            }
            if included, !value.toolIDs.contains(id.rawValue) {
                value.toolIDs.append(id.rawValue)
            } else if !included {
                value.toolIDs.removeAll { $0 == id.rawValue }
            }
        }
    }

    /// Changes product-level execution intent as one edit. The capability
    /// composer delegates the same transition here through `setTool`, keeping
    /// both profile-authoring surfaces consistent.
    func setExecutionRole(_ role: ProfileExecutionRole) {
        updateDraft { $0.setExecutionRole(role) }
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

    func coordinatorOptions(settings: SettingsStore) -> [ProfileModelOption] {
        ProfileBaseModelID.coordinatorCases.map {
            modelOption(for: $0, settings: settings)
        }
    }

    func workerOptions(settings: SettingsStore) -> [ProfileModelOption] {
        ProfileBaseModelID.workerCases.map {
            modelOption(for: $0, settings: settings)
        }
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
        if !ProfileBaseModelID.coordinatorCases.contains(id) {
            // A configured worker is necessary but not sufficient: only the
            // provider adapters in coordinatorCases implement delegate_task.
            compatible.remove(.delegateTask)
        }
        let subtitle: String
        switch id {
        case .onDevice: subtitle = "Private and optimized for compact tool schemas"
        case .llama: subtitle = "Local OpenAI-compatible model"
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
