import Foundation

nonisolated enum ProfileBaseModelID: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case onDevice = "on-device"
    case llama
    case pcc = "apple-pcc"
    case deepseek
    case codex

    /// Only provider-backed defaults belong in the profile library. Codex is
    /// configured contextually for delegated profiles; direct Codex selection
    /// remains owned by the composer.
    static let builtInCases: [Self] = [.onDevice, .llama, .pcc, .deepseek]
    /// These models expose the structured `delegate_task` route when selected
    /// in a custom profile. The built-in on-device profile remains direct;
    /// opting into this capability is an explicit override choice.
    static let delegationCases: [Self] = [.onDevice, .llama, .deepseek, .codex]
    /// Models available when creating or editing a custom profile. Codex is
    /// intentionally not a built-in standalone profile, but it is a valid
    /// override model with its own App Server and reasoning configuration.
    static let profileCases: [Self] = [.onDevice, .llama, .pcc, .deepseek, .codex]
    /// Compatibility alias for integrations that still describe the route as
    /// coordinator/worker. New UI and runtime code should use `delegationCases`.
    static let coordinatorCases: [Self] = delegationCases
    static let workerCases: [Self] = [.pcc, .llama, .deepseek]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onDevice: "On-device"
        case .llama: "Llama"
        case .pcc: "Apple PCC"
        case .deepseek: "DeepSeek"
        case .codex: "Codex"
        }
    }

    var systemImage: String {
        switch self {
        case .onDevice: "apple.logo"
        case .llama: "desktopcomputer"
        case .pcc: "cloud"
        case .deepseek: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    var remoteModelID: String? {
        switch self {
        case .onDevice, .codex: nil
        case .llama, .pcc, .deepseek: rawValue
        }
    }
}

nonisolated enum ProfileExecutionRole: String, CaseIterable, Identifiable, Sendable, Hashable {
    case direct
    case coordinatorWorker

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .direct: "Direct Model"
        case .coordinatorWorker: "Coordinator → Worker"
        }
    }

    var summary: String {
        switch self {
        case .direct:
            "The selected model handles requests with its included capabilities."
        case .coordinatorWorker:
            "The coordinator plans the request and delegates bounded implementation tasks to the selected worker."
        }
    }
}

nonisolated struct UserDynamicProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var summary: String
    var baseModelID: ProfileBaseModelID
    /// The provider-backed worker used when `delegate_task` is included.
    ///
    /// `nil` is retained for profiles written before M4.3 and resolves through
    /// the global worker preference, preserving their previous behavior.
    var workerModelID: String?
    /// Optional App Server selections owned by a Codex profile.
    ///
    /// Missing values deliberately mean "use the current Codex default", so
    /// profiles written before this field existed remain valid and selectable.
    var codexModelID: String?
    var codexReasoningEffort: CodexReasoningEffort?
    /// Optional worker capability override. `nil` preserves the safe, simple
    /// default: the selected worker receives its complete delegate tool set.
    /// An empty array is meaningful and represents a text-only worker profile.
    var workerToolIDs: [String]?
    var greedyMode: Bool
    var toolIDs: [String]
    var skillIDs: [String]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        baseModelID: ProfileBaseModelID,
        workerModelID: String? = nil,
        codexModelID: String? = nil,
        codexReasoningEffort: CodexReasoningEffort? = nil,
        workerToolIDs: [String]? = nil,
        greedyMode: Bool = false,
        toolIDs: [String] = [],
        skillIDs: [String] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.baseModelID = baseModelID
        self.workerModelID = workerModelID
        self.codexModelID = codexModelID
        self.codexReasoningEffort = codexReasoningEffort
        self.workerToolIDs = workerToolIDs?.uniqued()
        self.greedyMode = greedyMode
        self.toolIDs = toolIDs.uniqued()
        self.skillIDs = skillIDs.uniqued()
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, baseModelID, workerModelID
        case codexModelID, codexReasoningEffort
        case workerToolIDs
        case greedyMode, toolIDs, skillIDs
        case createdAt, updatedAt
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        baseModelID = try values.decode(ProfileBaseModelID.self, forKey: .baseModelID)
        workerModelID = try values.decodeIfPresent(String.self, forKey: .workerModelID)
        codexModelID = try values.decodeIfPresent(String.self, forKey: .codexModelID)
        codexReasoningEffort = try values.decodeIfPresent(
            CodexReasoningEffort.self,
            forKey: .codexReasoningEffort
        )
        workerToolIDs = try values.decodeIfPresent(
            [String].self,
            forKey: .workerToolIDs
        )?.uniqued()
        greedyMode = try values.decodeIfPresent(Bool.self, forKey: .greedyMode) ?? false
        toolIDs = try values.decodeIfPresent([String].self, forKey: .toolIDs) ?? []
        skillIDs = try values.decodeIfPresent([String].self, forKey: .skillIDs) ?? []
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    var resolvedToolIDs: Set<ToolCapabilityID> {
        // Profiles saved before the unified SwiftPM wrapper keep their capability
        // after upgrade instead of silently losing package initialization.
        var result = Set(toolIDs.compactMap { rawID in
            rawID == "swift_package_init"
                ? ToolCapabilityID.swiftPackageManager
                : ToolCapabilityID(rawValue: rawID)
        })
        if !skillIDs.isEmpty {
            result.insert(.loadSkill)
        }
        if !ProfileBaseModelID.delegationCases.contains(baseModelID) {
            // Delegate Task is a managed production route, not a portable
            // capability that arbitrary custom models may enable by stale data.
            result.remove(.delegateTask)
        }
        return result
    }

    /// The single source of truth for profile orchestration.
    ///
    /// A custom profile is delegated when its resolved capability set contains
    /// `delegate_task`; there is no separately persisted execution role.
    var usesDelegation: Bool {
        resolvedToolIDs.contains(.delegateTask)
    }

    /// Returns the explicit worker selection while preserving `nil` as the
    /// backwards-compatible "all worker tools" state.
    var resolvedWorkerToolIDs: Set<ToolCapabilityID>? {
        workerToolIDs.map { ids in
            Set(ids.compactMap(ToolCapabilityID.init(rawValue:)))
                .intersection(ModelToolCatalog.delegateToolIDs)
        }
    }

    /// Compatibility name retained for older callers while the product UI
    /// speaks in terms of profiles and delegation capability.
    @available(*, deprecated, message: "Use usesDelegation instead.")
    var isCoordinatorProfile: Bool { usesDelegation }

    /// Compatibility projection for older persisted-profile evaluations. It
    /// is derived and never drives UI or runtime selection.
    @available(*, deprecated, message: "Use usesDelegation instead.")
    var executionRole: ProfileExecutionRole {
        usesDelegation ? .coordinatorWorker : .direct
    }

    /// Compatibility migration helper for older creation flows. New code should
    /// include or remove `delegate_task` directly through `setTool`.
    mutating func setExecutionRole(_ role: ProfileExecutionRole) {
        switch role {
        case .direct:
            toolIDs.removeAll { $0 == ToolCapabilityID.delegateTask.rawValue }
            if baseModelID == .codex {
                // Codex custom profiles are currently route definitions; its
                // direct model/reasoning surface remains in the composer.
                // Returning to direct execution therefore selects the existing
                // customizable powerful-model profile instead of showing a
                // model that this editor cannot truthfully customize.
                baseModelID = .deepseek
            }
        case .coordinatorWorker:
            if !ProfileBaseModelID.delegationCases.contains(baseModelID) {
                baseModelID = .deepseek
            }
            // New routes are self-contained. Older routes may still carry nil
            // until edited, at which point the visible default becomes explicit.
            workerModelID = workerModelID ?? ProfileBaseModelID.llama.rawValue
            greedyMode = false
            if !toolIDs.contains(ToolCapabilityID.delegateTask.rawValue) {
                toolIDs.append(ToolCapabilityID.delegateTask.rawValue)
            }
        }
    }

    func validated() throws -> UserDynamicProfile {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        value.workerModelID = workerModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        value.codexModelID = codexModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.codexModelID?.isEmpty == true {
            value.codexModelID = nil
        }
        guard !value.name.isEmpty else { throw UserDynamicProfileError.missingName }
        guard value.name.count <= 64 else { throw UserDynamicProfileError.nameTooLong }
        value.toolIDs = toolIDs.uniqued()
        value.skillIDs = skillIDs.uniqued()
        value.workerToolIDs = workerToolIDs?
            .filter { id in
                guard let capability = ToolCapabilityID(rawValue: id) else {
                    return false
                }
                return ModelToolCatalog.delegateToolIDs.contains(capability)
            }
            .uniqued()
        return value
    }

    /// Resolves legacy profiles through the prior global preference while new
    /// profiles keep the route reproducible in their persisted definition.
    func resolvedWorkerModelID(fallback: String) -> String {
        guard let workerModelID,
              ProfileBaseModelID.workerCases.contains(where: {
                  $0.rawValue == workerModelID
              }) else {
            return fallback
        }
        return workerModelID
    }
}

nonisolated enum UserDynamicProfileError: LocalizedError {
    case missingName
    case nameTooLong
    case duplicateName(String)
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .missingName: "Enter a profile name."
        case .nameTooLong: "Profile names must be 64 characters or fewer."
        case .duplicateName(let name): "A profile named '\(name)' already exists."
        case .profileNotFound: "The selected profile no longer exists."
        }
    }
}

private nonisolated extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
