import Foundation
import Observation

nonisolated struct SkillModelProfileOption: Identifiable, Hashable, Sendable {
    let id: SkillModelProfileID
    let subtitle: String
    let tier: ModelToolTier
    let defaultToolIDs: Set<ToolCapabilityID>
    let compatibleToolIDs: Set<ToolCapabilityID>

    var defaultToolCount: Int { defaultToolIDs.count }
}

@MainActor
@Observable
final class SkillsViewModel {
    private let service: SkillEditingService
    private(set) var records: [SkillEditorRecord] = []
    private(set) var baseline: SkillDraft?
    var draft: SkillDraft?
    var selectedRecordID: String?
    var selectedProfileID: SkillModelProfileID = .onDevice
    var searchText = ""
    var toolSearchText = ""
    var errorMessage: String?
    var confirmationMessage: String?
    var pendingSelectionID: String?
    var pendingCreatesNewSkill = false

    init(service: SkillEditingService = .live) {
        self.service = service
    }

    var filteredRecords: [SkillEditorRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    var isDirty: Bool { draft != baseline }
    var canSave: Bool { draft != nil && isDirty }

    func reload(selecting preferredURL: URL? = nil) {
        records = service.loadRecords()
        let preferredID = preferredURL?.path ?? selectedRecordID
        if let preferredID, let record = records.first(where: { $0.id == preferredID }) {
            load(record)
        } else if draft == nil, let first = records.first {
            load(first)
        }
    }

    func requestSelection(_ recordID: String?) {
        guard recordID != selectedRecordID else { return }
        if isDirty {
            pendingSelectionID = recordID
            pendingCreatesNewSkill = false
            confirmationMessage = "Discard unsaved changes and open another skill?"
        } else {
            select(recordID)
        }
    }

    func requestNewSkill() {
        if isDirty {
            pendingSelectionID = nil
            pendingCreatesNewSkill = true
            confirmationMessage = "Discard unsaved changes and create a new skill?"
        } else {
            beginNewSkill()
        }
    }

    func confirmDiscard() {
        confirmationMessage = nil
        if pendingCreatesNewSkill {
            beginNewSkill()
        } else {
            select(pendingSelectionID)
        }
        pendingSelectionID = nil
        pendingCreatesNewSkill = false
    }

    func cancelDiscard() {
        confirmationMessage = nil
        pendingSelectionID = nil
        pendingCreatesNewSkill = false
    }

    func save() {
        guard let draft else { return }
        do {
            let saved = try service.save(draft)
            errorMessage = nil
            reload(selecting: saved.sourceURL)
            ChatStore.shared?.reloadSkills()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSelected() {
        guard let draft else { return }
        do {
            try service.delete(draft)
            self.draft = nil
            baseline = nil
            selectedRecordID = nil
            errorMessage = nil
            reload()
            ChatStore.shared?.reloadSkills()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func discardChanges() {
        draft = baseline
    }

    func updateDraft(_ mutation: (inout SkillDraft) -> Void) {
        guard var value = draft else { return }
        mutation(&value)
        draft = value
    }

    func override(for profileID: SkillModelProfileID) -> SkillModelOverride? {
        draft?.profileOverrides[profileID.rawValue]
    }

    func setOverrideEnabled(_ enabled: Bool, for profile: SkillModelProfileOption) {
        updateDraft { draft in
            if enabled {
                draft.profileOverrides[profile.id.rawValue] = SkillModelOverride()
            } else {
                draft.profileOverrides.removeValue(forKey: profile.id.rawValue)
            }
        }
    }

    func setInheritsDefaults(_ inherits: Bool, for profile: SkillModelProfileOption) {
        updateDraft { draft in
            guard var override = draft.profileOverrides[profile.id.rawValue] else { return }
            override.inheritsDefaults = inherits
            draft.profileOverrides[profile.id.rawValue] = override
        }
    }

    func addTool(_ toolID: ToolCapabilityID, to profile: SkillModelProfileOption) {
        guard profile.compatibleToolIDs.contains(toolID) else {
            errorMessage = "\(ModelToolCatalog.descriptor(for: toolID).name) is not compatible with \(profile.id.displayName)."
            return
        }
        updateDraft { draft in
            var override = draft.profileOverrides[profile.id.rawValue] ?? SkillModelOverride()
            guard !override.toolIDs.contains(toolID.rawValue) else { return }
            override.toolIDs.append(toolID.rawValue)
            draft.profileOverrides[profile.id.rawValue] = override
        }
    }

    func removeTool(_ toolID: String, from profile: SkillModelProfileOption) {
        updateDraft { draft in
            guard var override = draft.profileOverrides[profile.id.rawValue] else { return }
            override.toolIDs.removeAll { $0 == toolID }
            draft.profileOverrides[profile.id.rawValue] = override
        }
    }

    func modelProfiles(settings: SettingsStore) -> [SkillModelProfileOption] {
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: true,
            hasDelegateModel: true,
            repositoryMapDetail: .enhanced
        )

        func remote(_ id: String) -> RemoteModelConfig {
            settings.remoteModels.first(where: { $0.id == id })
                ?? RemoteModelConfig.defaults.first(where: { $0.id == id })!
        }

        let configurations: [(SkillModelProfileID, String, ModelToolTier, RemoteRepositoryMapCapability?)] = [
            (.onDevice, "Private and optimized for compact schemas", .onDevice, nil),
            (.llama, "Local OpenAI-compatible coding model", tier(for: remote("llama")), remote("llama").repositoryMap),
            (.pcc, "Apple Private Cloud Compute", tier(for: remote("apple-pcc")), remote("apple-pcc").repositoryMap),
            (.deepseek, "Premium enhanced coding model", tier(for: remote("deepseek")), remote("deepseek").repositoryMap)
        ]

        return configurations.map { id, subtitle, tier, repositoryMap in
            let profileContext = ToolAccessContext(
                hasWorkspace: context.hasWorkspace,
                hasSkills: context.hasSkills,
                hasDelegateModel: context.hasDelegateModel,
                repositoryMapDetail: repositoryMap?.detail
            )
            let plan = ModelToolCatalog.plan(profile: .standalone, tier: tier, context: profileContext)
            let defaults = plan.registeredIDs
            var compatible = defaults
            if id == .onDevice {
                compatible.insert(.writeOnDevice)
            }
            compatible.remove(.callPowerfulModel)
            return SkillModelProfileOption(
                id: id,
                subtitle: subtitle,
                tier: tier,
                defaultToolIDs: defaults,
                compatibleToolIDs: compatible
            )
        }
    }

    private func tier(for model: RemoteModelConfig) -> ModelToolTier {
        model.repositoryMap == .enhanced ? .enhanced : .standard
    }

    private func select(_ recordID: String?) {
        guard let recordID, let record = records.first(where: { $0.id == recordID }) else {
            draft = nil
            baseline = nil
            selectedRecordID = nil
            return
        }
        load(record)
    }

    private func load(_ record: SkillEditorRecord) {
        selectedRecordID = record.id
        guard let definition = record.definition else {
            draft = nil
            baseline = nil
            errorMessage = record.errorMessage
            return
        }
        let value = SkillDraft(definition: definition, builtInNames: SkillEditingService.builtInNames)
        draft = value
        baseline = value
        errorMessage = nil
    }

    private func beginNewSkill() {
        let existing = Set(records.map(\.displayName))
        var name = "new-skill"
        var suffix = 2
        while existing.contains(name) {
            name = "new-skill-\(suffix)"
            suffix += 1
        }
        let value = SkillDraft(suggestedName: name)
        draft = value
        baseline = nil
        selectedRecordID = nil
        selectedProfileID = .onDevice
        errorMessage = nil
    }
}
