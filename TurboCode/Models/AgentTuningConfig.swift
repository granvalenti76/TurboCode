import Foundation

nonisolated public struct AgentTuningConfig: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 3

    /// The former one-shot PCC Shortcut was persisted as a delegated worker
    /// even though it was never a remote model from `models.json`.
    private static let retiredPCCShortcutModelID = "pcc-shortcuts"

    public var schemaVersion: Int
    public var agent: AgentPolicy
    public var execution: ExecutionPolicy
    public var skills: SkillsPolicy
    public var git: GitPolicy
    public var orchestrator: OrchestratorPolicy
    /// Experimental integrations stay opt-in and are kept out of the default
    /// dynamic profile surface unless explicitly enabled by the user.
    public var experimental: ExperimentalPolicy

    public init(
        schemaVersion: Int = currentSchemaVersion,
        agent: AgentPolicy = AgentPolicy(),
        execution: ExecutionPolicy = ExecutionPolicy(),
        skills: SkillsPolicy = SkillsPolicy(),
        git: GitPolicy = GitPolicy(),
        orchestrator: OrchestratorPolicy = OrchestratorPolicy(),
        experimental: ExperimentalPolicy = ExperimentalPolicy()
    ) {
        self.schemaVersion = schemaVersion
        self.agent = agent
        self.execution = execution
        self.skills = skills
        self.git = git
        self.orchestrator = orchestrator
        self.experimental = experimental
    }

    public static var `default`: AgentTuningConfig { AgentTuningConfig() }

    public func validated() throws -> AgentTuningConfig {
        var value = self
        guard (0...Self.currentSchemaVersion).contains(schemaVersion) else {
            throw AgentTuningError.unsupportedSchemaVersion(schemaVersion)
        }
        // Preserve unknown worker IDs so Settings can still surface genuine
        // models.json mistakes; only the explicitly retired PCC Shortcut is
        // migrated to the standard delegated-worker fallback.
        if value.orchestrator.delegateModelID == Self.retiredPCCShortcutModelID {
            value.orchestrator.delegateModelID = OrchestratorPolicy().delegateModelID
        }
        // Older schemas represent shapes that remain structurally compatible.
        // Normalize their marker only after all values pass validation.
        value.schemaVersion = Self.currentSchemaVersion
        guard (5...600).contains(execution.defaultCommandTimeoutSeconds) else {
            throw AgentTuningError.invalidValue(
                field: "execution.defaultCommandTimeoutSeconds",
                "execution.defaultCommandTimeoutSeconds must be between 5 and 600"
            )
        }
        guard (5...600).contains(execution.maximumCommandTimeoutSeconds),
              execution.maximumCommandTimeoutSeconds >= execution.defaultCommandTimeoutSeconds else {
            throw AgentTuningError.invalidValue(
                field: "execution.maximumCommandTimeoutSeconds",
                "execution.maximumCommandTimeoutSeconds must be between the default timeout and 600"
            )
        }
        guard (1_000...30_000).contains(execution.maximumToolOutputCharacters) else {
            throw AgentTuningError.invalidValue(
                field: "execution.maximumToolOutputCharacters",
                "execution.maximumToolOutputCharacters must be between 1000 and 30000"
            )
        }
        guard !orchestrator.delegateModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTuningError.invalidValue(
                field: "orchestrator.delegateModelID",
                "orchestrator.delegateModelID must identify a model from models.json"
            )
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, agent, execution, skills, git, orchestrator, experimental
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        agent = try values.decodeIfPresent(AgentPolicy.self, forKey: .agent) ?? AgentPolicy()
        execution = try values.decodeIfPresent(ExecutionPolicy.self, forKey: .execution)
            ?? ExecutionPolicy()
        skills = try values.decodeIfPresent(SkillsPolicy.self, forKey: .skills) ?? SkillsPolicy()
        git = try values.decodeIfPresent(GitPolicy.self, forKey: .git) ?? GitPolicy()
        orchestrator = try values.decodeIfPresent(OrchestratorPolicy.self, forKey: .orchestrator)
            ?? OrchestratorPolicy()
        experimental = try values.decodeIfPresent(
            ExperimentalPolicy.self,
            forKey: .experimental
        ) ?? ExperimentalPolicy()
    }
}

/// User-controlled switches for integrations that can affect external apps.
/// New fields must default to disabled when decoding older configuration files.
nonisolated public struct ExperimentalPolicy: Codable, Hashable, Sendable {
    public var safariMCPEnabled: Bool
    /// Third-party Node plugins are an explicit trust-boundary opt-in. Keep
    /// this disabled when decoding older configurations.
    public var thirdPartyPluginsEnabled: Bool

    public init(
        safariMCPEnabled: Bool = false,
        thirdPartyPluginsEnabled: Bool = false
    ) {
        self.safariMCPEnabled = safariMCPEnabled
        self.thirdPartyPluginsEnabled = thirdPartyPluginsEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case safariMCPEnabled, thirdPartyPluginsEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        safariMCPEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .safariMCPEnabled
        ) ?? false
        thirdPartyPluginsEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .thirdPartyPluginsEnabled
        ) ?? false
    }
}

nonisolated public struct OrchestratorPolicy: Codable, Hashable, Sendable {
    /// ID of the remote model used by `call_powerful_model` in orchestrator mode.
    /// The ID is resolved against `~/.turbocode/models.json` at session creation.
    public var delegateModelID: String
    /// When enabled, `/task` and model-authored `delegate_task` calls return
    /// control after admission while the harness retains the worker operation.
    public var runsDelegatedTasksInBackground: Bool

    public init(
        delegateModelID: String = "llama",
        runsDelegatedTasksInBackground: Bool = false
    ) {
        self.delegateModelID = delegateModelID
        self.runsDelegatedTasksInBackground = runsDelegatedTasksInBackground
    }

    private enum CodingKeys: String, CodingKey {
        case delegateModelID, runsDelegatedTasksInBackground
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        delegateModelID = try values.decodeIfPresent(String.self, forKey: .delegateModelID)
            ?? "llama"
        // Older tuning files predate background delegation and must preserve
        // the blocking behavior users already reviewed.
        runsDelegatedTasksInBackground = try values.decodeIfPresent(
            Bool.self,
            forKey: .runsDelegatedTasksInBackground
        ) ?? false
    }
}

nonisolated public struct AgentPolicy: Codable, Hashable, Sendable {
    public var responseStyle: AgentResponseStyle
    public var verifiesChanges: Bool

    public init(
        responseStyle: AgentResponseStyle = .balanced,
        verifiesChanges: Bool = true
    ) {
        self.responseStyle = responseStyle
        self.verifiesChanges = verifiesChanges
    }

    private enum CodingKeys: String, CodingKey { case responseStyle, verifiesChanges }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        responseStyle = try values.decodeIfPresent(AgentResponseStyle.self, forKey: .responseStyle)
            ?? .balanced
        verifiesChanges = try values.decodeIfPresent(Bool.self, forKey: .verifiesChanges) ?? true
    }
}

nonisolated public enum AgentResponseStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case concise
    case balanced
    case detailed
}

nonisolated public struct ExecutionPolicy: Codable, Hashable, Sendable {
    public var defaultCommandTimeoutSeconds: Int
    public var maximumCommandTimeoutSeconds: Int
    public var maximumToolOutputCharacters: Int
    public var allowNetworkAccess: Bool

    public init(
        defaultCommandTimeoutSeconds: Int = 30,
        maximumCommandTimeoutSeconds: Int = 120,
        maximumToolOutputCharacters: Int = 12_000,
        allowNetworkAccess: Bool = true
    ) {
        self.defaultCommandTimeoutSeconds = defaultCommandTimeoutSeconds
        self.maximumCommandTimeoutSeconds = maximumCommandTimeoutSeconds
        self.maximumToolOutputCharacters = maximumToolOutputCharacters
        self.allowNetworkAccess = allowNetworkAccess
    }

    private enum CodingKeys: String, CodingKey {
        case defaultCommandTimeoutSeconds, maximumCommandTimeoutSeconds
        case maximumToolOutputCharacters, allowNetworkAccess
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultCommandTimeoutSeconds = try values.decodeIfPresent(
            Int.self,
            forKey: .defaultCommandTimeoutSeconds
        ) ?? 30
        maximumCommandTimeoutSeconds = try values.decodeIfPresent(
            Int.self,
            forKey: .maximumCommandTimeoutSeconds
        ) ?? 120
        maximumToolOutputCharacters = try values.decodeIfPresent(
            Int.self,
            forKey: .maximumToolOutputCharacters
        ) ?? 12_000
        allowNetworkAccess = try values.decodeIfPresent(Bool.self, forKey: .allowNetworkAccess)
            ?? true
    }
}

nonisolated public struct SkillsPolicy: Codable, Hashable, Sendable {
    public var discoversUserSkills: Bool

    public init(discoversUserSkills: Bool = true) {
        self.discoversUserSkills = discoversUserSkills
    }

    private enum CodingKeys: String, CodingKey { case discoversUserSkills }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        discoversUserSkills = try values.decodeIfPresent(Bool.self, forKey: .discoversUserSkills)
            ?? true
    }
}

nonisolated public struct GitPolicy: Codable, Hashable, Sendable {
    public var allowsCommits: Bool
    public var allowsRemoteWrites: Bool
    public var confirmsDestructiveOperations: Bool

    public init(
        allowsCommits: Bool = true,
        allowsRemoteWrites: Bool = true,
        confirmsDestructiveOperations: Bool = true
    ) {
        self.allowsCommits = allowsCommits
        self.allowsRemoteWrites = allowsRemoteWrites
        self.confirmsDestructiveOperations = confirmsDestructiveOperations
    }

    private enum CodingKeys: String, CodingKey {
        case allowsCommits, allowsRemoteWrites, confirmsDestructiveOperations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allowsCommits = try values.decodeIfPresent(Bool.self, forKey: .allowsCommits) ?? true
        allowsRemoteWrites = try values.decodeIfPresent(Bool.self, forKey: .allowsRemoteWrites)
            ?? true
        confirmsDestructiveOperations = try values.decodeIfPresent(
            Bool.self,
            forKey: .confirmsDestructiveOperations
        ) ?? true
    }
}

nonisolated public enum AgentTuningError: LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidValue(field: String, String)
    case malformed(field: String, message: String)

    public var field: String {
        switch self {
        case .unsupportedSchemaVersion:
            "schemaVersion"
        case .invalidValue(let field, _), .malformed(let field, _):
            field
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported Agent Tuning schema version: \(version)"
        case .invalidValue(let field, let message):
            "Invalid Agent Tuning value at \(field): \(message)"
        case .malformed(let field, let message):
            "Invalid Agent Tuning configuration at \(field): \(message)"
        }
    }
}
