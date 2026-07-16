import Foundation

// MARK: - TurboCode Configuration

/// Manages the `~/.turbocode/` directory and configuration files.
/// Created on first launch with sensible defaults.
public final class TurboCodeConfig {
    public static let shared = TurboCodeConfig()

    private var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode")
    }

    private var modelsURL: URL { rootURL.appendingPathComponent("models.json") }
    public var modelsConfigurationURL: URL { modelsURL }
    public var dynamicProfilesURL: URL { rootURL.appendingPathComponent("profiles.json") }
    private var agentTuningURL: URL { rootURL.appendingPathComponent("config.json") }
    private var sessionsDir: URL { rootURL.appendingPathComponent("sessions") }
    public var skillsDirectoryURL: URL { rootURL.appendingPathComponent("SKILLS", isDirectory: true) }
    public var diagnosticsDirectoryURL: URL { rootURL.appendingPathComponent("diagnostics", isDirectory: true) }
    public var repositoryMapCacheDirectoryURL: URL {
        rootURL.appendingPathComponent("cache/repository-maps", isDirectory: true)
    }
    public var documentationDirectoryURL: URL {
        rootURL.appendingPathComponent("documentation", isDirectory: true)
    }
    public var officialDocumentationDirectoryURL: URL {
        documentationDirectoryURL.appendingPathComponent("official", isDirectory: true)
    }
    public var userDocumentationDirectoryURL: URL {
        documentationDirectoryURL.appendingPathComponent("user", isDirectory: true)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    // MARK: - First Launch

    public var isOnboarded: Bool {
        FileManager.default.fileExists(atPath: rootURL.path)
            && FileManager.default.fileExists(atPath: sessionsDir.path)
            && FileManager.default.fileExists(atPath: skillsDirectoryURL.path)
            && FileManager.default.fileExists(atPath: modelsURL.path)
            && FileManager.default.fileExists(atPath: agentTuningURL.path)
    }

    public func performOnboarding() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: officialDocumentationDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: userDocumentationDirectoryURL,
            withIntermediateDirectories: true
        )
        try migrateRemoteModels()
        try migrateAgentTuning()

        try installBuiltInSkill(name: "turbocode", contents: Self.turboCodeSkill)
        try migrateTurboCodeSkill()
        try installBuiltInSkill(name: "skill-creator", contents: Self.skillCreatorSkill)
    }

    // MARK: - Skills

    func loadSkills() -> [TurboCodeSkillDefinition] {
        guard let enumerator = FileManager.default.enumerator(
            at: skillsDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let resolvedSkillsRoot = skillsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let allowedPrefix = resolvedSkillsRoot.path + "/"
        let skillFiles = enumerator.compactMap { $0 as? URL }
            .filter { url in
                guard url.lastPathComponent == "SKILL.md" else { return false }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                return resolved.path.hasPrefix(allowedPrefix)
            }
            .sorted { $0.path < $1.path }

        var skillsByName: [String: TurboCodeSkillDefinition] = [:]
        for url in skillFiles {
            do {
                let skill = try TurboCodeSkillDefinition(contentsOf: url)
                if skillsByName[skill.name] == nil {
                    skillsByName[skill.name] = skill
                } else {
                    print("[TurboCode] Ignoring duplicate skill '\(skill.name)' at \(url.path)")
                }
            } catch {
                print("[TurboCode] Ignoring invalid skill at \(url.path): \(error.localizedDescription)")
            }
        }
        return skillsByName.values.sorted { $0.name < $1.name }
    }

    private func installBuiltInSkill(name: String, contents: String) throws {
        let directory = skillsDirectoryURL.appendingPathComponent(name, isDirectory: true)
        let url = directory.appendingPathComponent("SKILL.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func migrateTurboCodeSkill() throws {
        let url = skillsDirectoryURL
            .appendingPathComponent("turbocode", isDirectory: true)
            .appendingPathComponent("SKILL.md")
        var contents = try String(contentsOf: url, encoding: .utf8)
        var changed = false

        if !contents.contains(Self.providerCredentialsSkillMarker) {
            let previousDescription = "description: Explain TurboCode, its model modes, workspace tools, approvals, skills, and interface behavior"
            if contents.contains(previousDescription) {
                contents = contents.replacingOccurrences(
                    of: previousDescription,
                    with: Self.turboCodeSkillDescription
                )
            }
            contents += "\n\n" + Self.providerCredentialsSkillSection + "\n"
            changed = true
        }
        if !contents.contains(Self.contextPolicySkillMarker) {
            contents += "\n\n" + Self.contextPolicySkillSection + "\n"
            changed = true
        }
        if !contents.contains(Self.productScopeSkillMarker) {
            contents += "\n\n" + Self.productScopeSkillSection + "\n"
            changed = true
        }
        if !contents.contains(Self.agentTuningSkillMarker) {
            contents += "\n\n" + Self.agentTuningSkillSection + "\n"
            changed = true
        }
        if !contents.contains(Self.repositoryMapSkillMarker) {
            contents += "\n\n" + Self.repositoryMapSkillSection + "\n"
            changed = true
        }
        if !contents.contains(Self.xcodeProjectSkillMarker) {
            contents += "\n\n" + Self.xcodeProjectSkillSection + "\n"
            changed = true
        }
        if !contents.contains(Self.pccSetupSkillMarker) {
            contents += "\n\n" + Self.pccSetupSkillSection + "\n"
            changed = true
        }
        if changed {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let turboCodeSkillDescription =
        "description: Explain TurboCode, model and provider setup, credentials, workspace tools, approvals, skills, and interface behavior"

    private static let providerCredentialsSkillMarker =
        "<!-- turbocode-managed:provider-credentials-v1 -->"

    private static let providerCredentialsSkillSection = """
    <!-- turbocode-managed:provider-credentials-v1 -->
    ## Premium providers and API keys

    - The built-in premium option is currently `deepseek-v4-flash`.
    - To configure it, open **TurboCode > Settings > Providers > DeepSeek** and
      enter the API key in **API Key**.
    - TurboCode stores the secret in the macOS Keychain. Never tell the user to
      place an API key in `~/.turbocode/models.json`, source files, or chat.
    - `~/.turbocode/models.json` contains non-secret provider configuration such
      as the model name, endpoint, capabilities, and the Keychain credential
      reference `"credential": "deepseek"`.
    - If DeepSeek is disabled in the model menu, ask the user to verify that the
      key has been entered in Provider Settings.
    """

    private static let contextPolicySkillMarker =
        "<!-- turbocode-managed:tool-context-policy-v1 -->"

    private static let contextPolicySkillSection = """
    <!-- turbocode-managed:tool-context-policy-v1 -->
    ## Tool context policy

    Preserving the useful context window is a core TurboCode product principle.
    Foundation Apple, Apple PCC, Llama, and the orchestrator discard completed
    tool-call exchanges before later generations. Keep this behavior when adding
    profiles or providers: tool results should accomplish the operation without
    permanently consuming the prompt budget.

    DeepSeek thinking is a transport-level exception because its API requires
    complete reasoning and tool-call turns to be sent back in later requests.
    TurboCode preserves and normalizes those wire messages only for DeepSeek; this
    exception must not weaken completed-tool-call dropping for other models.
    """

    private static let productScopeSkillMarker =
        "<!-- turbocode-managed:product-scope-v1 -->"

    private static let productScopeSkillSection = """
    <!-- turbocode-managed:product-scope-v1 -->
    ## Product scope

    TurboCode is a native macOS agentic development environment dedicated to
    Swift and SwiftUI. Its supported workflow is to inspect, modify, build, test,
    run, and manage Git-backed Xcode projects and Swift packages inside the active
    workspace.

    TurboCode is not a general desktop agent, broad multi-language IDE, terminal
    replacement, or generic web assistant. It may edit documentation, resources,
    and configuration when they directly belong to a Swift project task. For a
    request outside this boundary, explain the limitation concisely and state what
    related Swift-project work TurboCode can perform.

    The underlying model changes capacity, not the product contract. Prefer flat
    tools for small models and advanced atomic tools for capable models while
    preserving the same workspace, review, Git, and recovery guarantees.
    """

    private static let agentTuningSkillMarker =
        "<!-- turbocode-managed:agent-tuning-v1 -->"

    private static let repositoryMapSkillMarker =
        "<!-- turbocode-managed:repository-map-v1 -->"

    private static let xcodeProjectSkillMarker =
        "<!-- turbocode-managed:xcode-project-v1 -->"

    private static let pccSetupSkillMarker =
        "<!-- turbocode-managed:pcc-setup-v1 -->"

    private static let agentTuningSkillSection = """
    <!-- turbocode-managed:agent-tuning-v1 -->
    ## Agent Tuning

    Common response, execution, network, and skill-discovery options are in
    **TurboCode > Settings > Agents**. Advanced configuration is stored in the
    versioned `~/.turbocode/config.json` file and can be reloaded from that pane.

    Never put API keys in `config.json`. Secrets belong in the macOS Keychain.
    If configuration validation fails, explain the reported field or range and
    preserve the user's file instead of suggesting that it be reset blindly.
    """

    private static let repositoryMapSkillSection = """
    <!-- turbocode-managed:repository-map-v1 -->
    ## Swift workspace map

    Capable standalone and delegated models receive `swift_workspace_map` for
    existing Swift, SwiftUI, Xcode, and Swift Package workspaces. Use its compact
    overview, symbol search, and related-declaration queries before reading large
    files. Then use `read_file` only for the focused line ranges needed by the
    task. Apple on-device does not receive this tool; in orchestrator mode the
    configured delegate maps the project.
    """

    private static let xcodeProjectSkillSection = """
    <!-- turbocode-managed:xcode-project-v1 -->
    ## Xcode project validation

    Capable standalone and delegated models receive `xcode_project` with flat
    `inspect`, `build`, and `test` actions. Prefer it over `bash` for Xcode work:
    it discovers schemes, reuses Xcode's incremental build state, parses
    `.xcresult`, and
    returns bounded source diagnostics instead of raw compiler logs. Apple
    on-device does not receive this tool and delegates Xcode work in Orchestrator
    mode. Build duration remains bounded by the maximum timeout in Agent Settings.
    """

    private static let pccSetupSkillSection = """
    <!-- turbocode-managed:pcc-setup-v1 -->
    ## Apple PCC setup

    Apple on-device is loaded directly by the Foundation Models framework and
    needs no local server. Apple PCC uses the framework's local Chat Completions
    bridge. When the user asks how to configure or start PCC, tell them to open
    Terminal and run:

    ```shell
    fm serve --port 1976
    ```

    The process must remain running while PCC is in use. TurboCode already
    configures `http://127.0.0.1:1976/v1` with model `pcc`, so no API key or manual
    endpoint change is required. The local health endpoint is
    `http://127.0.0.1:1976/health`. Then the user can select Apple PCC in Standalone
    mode or as the delegate in **TurboCode > Settings > Agents > Orchestrator**.
    """

    private static let turboCodeSkill = """
    ---
    name: turbocode
    \(turboCodeSkillDescription)
    ---
    # TurboCode

    TurboCode is a native macOS coding assistant built with SwiftUI. Always identify
    yourself as TurboCode, never as an Apple product or as the underlying model.

    ## Model modes

    - Standalone gives the selected model direct access to workspace tools.
    - Orchestrator uses the Apple on-device model to coordinate work and delegates
      complex coding tasks to the configured powerful model.
    - Available backends can include Foundation Apple, Apple PCC, and Llama-server.

    \(providerCredentialsSkillSection)

    \(pccSetupSkillSection)

    \(contextPolicySkillSection)

    \(productScopeSkillSection)

    \(agentTuningSkillSection)

    ## Workspace tools

    - `read_file` reads complete files or focused numbered line ranges.
    - `grep` searches workspace text.
    - `file_system` lists and manages files inside the workspace.
    - `git` initializes repositories and provides complete structured local and
      remote Git workflows. Git writes are independent from the read-only bash
      sandbox. Destructive operations are presented for approval before execution.
    - `bash` runs bounded commands with read-only workspace access in a macOS process sandbox.
    - `xcode_project` inspects, builds, and tests Xcode containers with compact
      structured diagnostics for capable models.
    - Every model uses the flat single-change `edit_file` schema. TurboCode handles
      transaction assembly internally and presents the review widget with additions,
      deletions, Review, and Undo.
    - Text creation and editing run automatically. File or directory deletion and
      destructive Git operations ask for approval.

    TurboCode never removes project files when a workspace is removed from the
    sidebar. It removes only the workspace reference and associated chat sessions.

    \(repositoryMapSkillSection)

    \(xcodeProjectSkillSection)

    ## Skills

    Skills are discovered automatically from `~/.turbocode/SKILLS/**/SKILL.md`.
    Their names and descriptions stay in the session instructions; their full body
    is loaded on demand when relevant. Users can type `/skills`, `/skill <name>`, or
    `/<skill-name>` in the composer.
    """

    private static let skillCreatorSkill = """
    ---
    name: skill-creator
    description: Design a reusable TurboCode skill and produce a valid SKILL.md with concise activation metadata
    ---
    # Skill Creator

    Help the user design a reusable TurboCode skill. A skill lives at
    `~/.turbocode/SKILLS/<skill-name>/SKILL.md` and uses this format:

    ```markdown
    ---
    name: lowercase-kebab-name
    description: State precisely when the model should activate this skill
    ---
    # Skill Title

    Operational instructions, decision rules, examples, and relevant constraints.
    ```

    Keep the name under 64 characters and use lowercase letters, digits, and hyphens.
    Make the description specific enough for automatic activation. Keep the body
    procedural and focused; avoid repeating general TurboCode behavior. When asked
    to create a skill, return the complete `SKILL.md` and its intended directory.
    TurboCode discovers valid files automatically before the next submitted prompt.
    """

    // MARK: - Agent Tuning

    public func loadAgentTuning() throws -> AgentTuningConfig {
        guard FileManager.default.fileExists(atPath: agentTuningURL.path) else {
            return .default
        }
        let value = try JSONDecoder().decode(
            AgentTuningConfig.self,
            from: Data(contentsOf: agentTuningURL)
        )
        return try value.validated()
    }

    public func saveAgentTuning(_ value: AgentTuningConfig) throws {
        let validated = try value.validated()
        try encoder.encode(validated).write(to: agentTuningURL, options: .atomic)
    }

    private func migrateAgentTuning() throws {
        if FileManager.default.fileExists(atPath: agentTuningURL.path) {
            _ = try loadAgentTuning()
        } else {
            try saveAgentTuning(.default)
        }
    }

    // MARK: - Remote Models

    public func loadRemoteModels() throws -> [RemoteModelConfig] {
        guard FileManager.default.fileExists(atPath: modelsURL.path) else { return [] }
        return try JSONDecoder().decode([RemoteModelConfig].self, from: Data(contentsOf: modelsURL))
    }

    private func migrateRemoteModels() throws {
        var models: [RemoteModelConfig]
        if FileManager.default.fileExists(atPath: modelsURL.path) {
            models = try loadRemoteModels()
        } else {
            models = []
        }
        if let index = models.firstIndex(where: {
            $0.id == "deepseek" && $0.modelName == "deepseek-v4-pro"
        }) {
            models[index].name = "DeepSeek V4 Flash"
            models[index].modelName = "deepseek-v4-flash"
        }
        for model in RemoteModelConfig.defaults where !models.contains(where: { $0.id == model.id }) {
            models.append(model)
        }
        try encoder.encode(models).write(to: modelsURL, options: .atomic)
    }

    // MARK: - Per-Session Persistence

    /// Saves one session to `~/.turbocode/sessions/<id>.json`.
    /// Creates the sessions directory if needed.
    public func saveSession(_ session: StoredSession) throws {
        let dir = sessionsDir
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = sessionURL(for: session.id)
        try encoder.encode(session).write(to: url, options: .atomic)
        print("[TurboCode] Saved session \(session.id) → \(url.path)")
    }

    /// Loads one session by id.
    public func loadSession(id: String) throws -> StoredSession? {
        let url = sessionURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(StoredSession.self, from: Data(contentsOf: url))
    }

    /// Lists all session files, optionally filtered by project name.
    public func listSessions(project: String? = nil) throws -> [StoredSession] {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
            return []
        }
        let files = try FileManager.default.contentsOfDirectory(at: sessionsDir,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        let all: [StoredSession] = try files.compactMap { url in
            try JSONDecoder().decode(StoredSession.self, from: Data(contentsOf: url))
        }
        if let project {
            return all.filter { $0.projectName == project }
        }
        return all
    }

    /// Deletes a session file.
    public func deleteSession(id: String) throws {
        let url = sessionURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func sessionURL(for id: String) -> URL {
        sessionsDir.appendingPathComponent("\(id).json")
    }
}

// MARK: - Remote Model Configuration

nonisolated public enum RemoteModelProvider: String, Codable, Hashable, Sendable {
    case openAICompatible
    case deepseek
}

nonisolated public enum RemoteModelRole: String, Codable, Hashable, Sendable {
    case local
    case pcc
    case premium
}

nonisolated public enum RemoteReasoningTransport: String, Codable, Hashable, Sendable {
    case contextOptions
    case deepseekThinking
    case none
}

nonisolated public enum RemoteRepositoryMapCapability: String, Codable, Hashable, Sendable {
    case none
    case compact
    case enhanced
}

nonisolated extension RemoteRepositoryMapCapability {
    var detail: RepositoryMapDetail? {
        switch self {
        case .none: nil
        case .compact: .compact
        case .enhanced: .enhanced
        }
    }
}

nonisolated public struct RemoteModelConfig: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var url: String
    public var modelName: String
    public var temperature: Double
    public var provider: RemoteModelProvider
    public var role: RemoteModelRole
    public var reasoningTransport: RemoteReasoningTransport
    public var supportsReasoning: Bool
    public var supportsGuidedGeneration: Bool
    public var contextWindowTokens: Int
    public var repositoryMap: RemoteRepositoryMapCapability
    public var credential: String?
    public var enabled: Bool

    public init(
        id: String,
        name: String,
        url: String,
        modelName: String,
        temperature: Double,
        provider: RemoteModelProvider = .openAICompatible,
        role: RemoteModelRole = .local,
        reasoningTransport: RemoteReasoningTransport = .contextOptions,
        supportsReasoning: Bool = true,
        supportsGuidedGeneration: Bool = true,
        contextWindowTokens: Int = 32_768,
        repositoryMap: RemoteRepositoryMapCapability = .compact,
        credential: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id; self.name = name; self.url = url
        self.modelName = modelName; self.temperature = temperature
        self.provider = provider; self.role = role
        self.reasoningTransport = reasoningTransport
        self.supportsReasoning = supportsReasoning
        self.supportsGuidedGeneration = supportsGuidedGeneration
        self.contextWindowTokens = contextWindowTokens
        self.repositoryMap = repositoryMap
        self.credential = credential; self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, modelName, temperature, provider, role
        case reasoningTransport, supportsReasoning, supportsGuidedGeneration
        case contextWindowTokens, repositoryMap
        case credential, enabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        url = try values.decode(String.self, forKey: .url)
        modelName = try values.decode(String.self, forKey: .modelName)
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.6
        provider = try values.decodeIfPresent(RemoteModelProvider.self, forKey: .provider)
            ?? (id == "deepseek" ? .deepseek : .openAICompatible)
        role = try values.decodeIfPresent(RemoteModelRole.self, forKey: .role)
            ?? (id == "apple-pcc" ? .pcc : (provider == .deepseek ? .premium : .local))
        reasoningTransport = try values.decodeIfPresent(RemoteReasoningTransport.self, forKey: .reasoningTransport)
            ?? (provider == .deepseek ? .deepseekThinking : (role == .pcc ? .none : .contextOptions))
        supportsReasoning = try values.decodeIfPresent(Bool.self, forKey: .supportsReasoning)
            ?? (role != .pcc)
        supportsGuidedGeneration = try values.decodeIfPresent(Bool.self, forKey: .supportsGuidedGeneration)
            ?? (provider != .deepseek)
        contextWindowTokens = try values.decodeIfPresent(Int.self, forKey: .contextWindowTokens)
            ?? (provider == .deepseek ? 128_000 : 32_768)
        repositoryMap = try values.decodeIfPresent(
            RemoteRepositoryMapCapability.self,
            forKey: .repositoryMap
        ) ?? (provider == .deepseek ? .enhanced : .compact)
        credential = try values.decodeIfPresent(String.self, forKey: .credential)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public static let defaults: [RemoteModelConfig] = [
        RemoteModelConfig(
            id: "llama",
            name: "Llama-server",
            url: "http://127.0.0.1:8080/v1",
            modelName: "local-model",
            temperature: 0.6
        ),
        RemoteModelConfig(
            id: "apple-pcc",
            name: "Apple PCC",
            url: "http://127.0.0.1:1976/v1",
            modelName: "pcc",
            temperature: 0.6,
            role: .pcc,
            reasoningTransport: .none,
            supportsReasoning: false
        ),
        RemoteModelConfig(
            id: "deepseek",
            name: "DeepSeek V4 Flash",
            url: "https://api.deepseek.com",
            modelName: "deepseek-v4-flash",
            temperature: 0.6,
            provider: .deepseek,
            role: .premium,
            reasoningTransport: .deepseekThinking,
            supportsGuidedGeneration: false,
            contextWindowTokens: 128_000,
            repositoryMap: .enhanced,
            credential: "deepseek"
        )
    ]

    public static var fallbackLlama: RemoteModelConfig {
        defaults.first(where: { $0.id == "llama" })!
    }
}

// MARK: - Stored Session

/// A full persisted session: metadata + conversation blocks.
public struct StoredSession: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var projectName: String
    public var workspacePath: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var modelBackend: String
    public var blocks: [StoredBlock]

    public init(id: String = UUID().uuidString, title: String,
                projectName: String, workspacePath: String? = nil,
                createdAt: Date = .now, updatedAt: Date = .now,
                modelBackend: String = "Llama-server",
                blocks: [StoredBlock] = []) {
        self.id = id; self.title = title; self.projectName = projectName
        self.workspacePath = workspacePath; self.createdAt = createdAt
        self.updatedAt = updatedAt; self.modelBackend = modelBackend
        self.blocks = blocks
    }
}

// MARK: - Stored Block

/// Codable snapshot of a ChatBlock.
public struct StoredBlock: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: String     // ChatBlockKind rawValue
    public let text: String
    public let createdAt: Date
    public var model: String?
    public var providerId: String?
    public var diffPatch: DiffPatchBlock?
    public var gitCommit: GitCommitBlock?
    public var productGuide: ProductGuideBlock?
    public var workspaceListing: WorkspaceListingBlock?

    public init(id: String = UUID().uuidString, kind: String, text: String,
                createdAt: Date = .now, model: String? = nil, providerId: String? = nil,
                diffPatch: DiffPatchBlock? = nil, gitCommit: GitCommitBlock? = nil,
                productGuide: ProductGuideBlock? = nil,
                workspaceListing: WorkspaceListingBlock? = nil) {
        self.id = id; self.kind = kind; self.text = text
        self.createdAt = createdAt; self.model = model; self.providerId = providerId
        self.diffPatch = diffPatch
        self.gitCommit = gitCommit
        self.productGuide = productGuide
        self.workspaceListing = workspaceListing
    }
}
