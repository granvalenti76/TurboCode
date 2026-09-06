import Foundation

// MARK: - TurboCode Configuration

/// Manages the `~/.turbocode/` directory and configuration files.
/// Created on first launch with sensible defaults.
public final class TurboCodeConfig {
    public static let shared = TurboCodeConfig()

    private let rootURL: URL

    private init() {
        rootURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode", isDirectory: true)
    }

    /// Injectable root used by first-launch and migration tests.
    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private var modelsURL: URL { rootURL.appendingPathComponent("models.json") }
    public var modelsConfigurationURL: URL { modelsURL }
    public var dynamicProfilesURL: URL { rootURL.appendingPathComponent("profiles.json") }
    /// The single canonical installation root for TypeScript plugins.
    public var pluginsDirectoryURL: URL {
        rootURL.appendingPathComponent("plugins", isDirectory: true)
    }
    /// Local SDK packages are kept outside installed plugins so ordinary
    /// TypeScript projects can import the stable package name without a
    /// relative path into TurboCode's source tree.
    public var sdkDirectoryURL: URL {
        rootURL.appendingPathComponent("sdk", isDirectory: true)
    }
    public var agentTuningConfigurationURL: URL { agentTuningURL }
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
            && FileManager.default.fileExists(atPath: dynamicProfilesURL.path)
            && FileManager.default.fileExists(atPath: sdkDirectoryURL.path)
            && FileManager.default.fileExists(atPath: diagnosticsDirectoryURL.path)
            && FileManager.default.fileExists(atPath: repositoryMapCacheDirectoryURL.path)
            && FileManager.default.fileExists(atPath: officialDocumentationDirectoryURL.path)
            && FileManager.default.fileExists(atPath: userDocumentationDirectoryURL.path)
    }

    public func performOnboarding() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: pluginsDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sdkDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: diagnosticsDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repositoryMapCacheDirectoryURL,
            withIntermediateDirectories: true
        )
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
        try DynamicProfileStore(fileURL: dynamicProfilesURL).migrate()
        if !FileManager.default.fileExists(atPath: dynamicProfilesURL.path) {
            try DynamicProfileStore(fileURL: dynamicProfilesURL).save([])
        }

        try installBuiltInSkill(name: "turbocode", contents: Self.turboCodeSkill)
        try migrateTurboCodeSkill()
        try installBuiltInSkill(name: "skill-creator", contents: Self.skillCreatorSkill)
    }

    // MARK: - Skills

    /// Loads legacy TurboCode skills together with Codex-compatible skills.
    /// Repository skills are discovered from `.agents/skills` at the selected
    /// workspace and its parents, matching Codex's repository scope rules.
    func loadSkills(workspaceRoot: String? = nil) -> [TurboCodeSkillDefinition] {
        let roots = skillRoots(workspaceRoot: workspaceRoot)
        let skillFiles = roots.flatMap(skillFiles(in:)).sorted { $0.path < $1.path }

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

    private func skillRoots(workspaceRoot: String?) -> [URL] {
        var roots = [skillsDirectoryURL]
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode", isDirectory: true)
        if rootURL.standardizedFileURL == defaultRoot.standardizedFileURL {
            roots.append(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".agents/skills", isDirectory: true)
            )
        }
        if let workspaceRoot,
           !workspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var current = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
            while current.path != current.deletingLastPathComponent().path {
                roots.append(current.appendingPathComponent(".agents/skills", isDirectory: true))
                current.deleteLastPathComponent()
            }
        }
        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func skillFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let allowedPrefix = resolvedRoot.path + "/"
        return enumerator.compactMap { $0 as? URL }
            .filter { url in
                guard url.lastPathComponent == "SKILL.md" else { return false }
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                return resolved.path.hasPrefix(allowedPrefix)
            }
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
        if let markerRange = contents.range(of: Self.pccSetupSkillMarker) {
            let sectionEnd = contents.range(
                of: "\n\n<!-- turbocode-managed:",
                range: markerRange.upperBound..<contents.endIndex
            )?.lowerBound ?? contents.endIndex
            let currentSection = contents[markerRange.lowerBound..<sectionEnd]
            if String(currentSection) != Self.pccSetupSkillSection {
                contents.replaceSubrange(
                    markerRange.lowerBound..<sectionEnd,
                    with: Self.pccSetupSkillSection
                )
                changed = true
            }
        } else {
            contents += "\n\n" + Self.pccSetupSkillSection + "\n"
            changed = true
        }
        if changed {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let turboCodeSkillDescription =
        "description: Explain TurboCode, providers, workspace tools, approvals, skills, TypeScript plugins, and interface behavior"

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
    Foundation Apple, Llama, and the orchestrator discard completed
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

    TurboCode is a native macOS agentic environment. The active workspace is its
    default working directory, not a limitation on the kind of project or task.
    Tools may access external filesystem paths after TurboCode obtains host-owned
    user approval for the exact operation.

    Let the model choose the available tool and workflow that best fit the task.
    Structured tools add native review and presentation but do not prohibit Bash
    or impose a language, framework, or application category.
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
    overview, symbol search, and related-declaration queries. Apple on-device does
    not receive this tool; in the experimental
    delegation mode the configured worker maps the project.
    """

    private static let xcodeProjectSkillSection = """
    <!-- turbocode-managed:xcode-project-v1 -->
    ## Xcode project validation

    Capable standalone and delegated models receive `xcode_project` with flat
    `inspect`, `build`, and `test` actions. It discovers schemes, reuses Xcode's
    incremental build state, parses
    `.xcresult`, and
    returns bounded source diagnostics instead of raw compiler logs. Apple
    on-device does not receive this tool and delegates Xcode work in Orchestrator
    mode. Build duration remains bounded by the maximum timeout in Agent Settings.
    """

    private static let pccSetupSkillSection = """
    <!-- turbocode-managed:pcc-setup-v1 -->
    ## Apple PCC status

    Apple PCC through `fm serve` is retired and is not a selectable TurboCode
    profile, override, composer model, or delegated worker. Do not recommend
    starting `fm serve` or configuring the old PCC endpoint.
    PCC-RETIREMENT: remove this managed compatibility section with the legacy
    provider code.
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
    - Available backends can include Foundation Apple and Llama-server.

    \(providerCredentialsSkillSection)

    \(pccSetupSkillSection)

    \(contextPolicySkillSection)

    \(productScopeSkillSection)

    \(agentTuningSkillSection)

    ## Workspace tools

    - `read_file` reads numbered line ranges and reports an exact continuation when output reaches its configured ceiling.
    - `ripgrep` discovers workspace files or searches their text with optional filters.
    - `file_system` lists and manages files; external paths pause for approval.
    - `git` initializes repositories and provides complete structured local and
      remote Git workflows. Destructive operations are presented for approval
      before execution.
    - `bash` runs bounded commands from the active workspace and may write inside
      it. Access outside the workspace is denied first and can continue only after
      TurboCode presents the exact command for host-owned user approval. Every call
      starts again from the reported working directory; `cd` never changes the
      workspace used by later calls.
    - `swift_package_manager` provides structured SwiftPM initialization, dependency
      editing, resolution, builds, tests, runs, cleanup, and package inspection.
    - `xcode_project` inspects, builds, and tests Xcode containers with compact
      structured diagnostics for capable models.
    - `edit_file` supports atomic changes inside or outside the workspace and presents
      the review widget with additions, deletions, Review, and Undo.
    - Text creation and editing run automatically. File or directory deletion and
      destructive Git operations ask for approval.

    TurboCode never removes project files when a workspace is removed from the
    sidebar. It removes only the workspace reference and associated chat sessions.

    \(repositoryMapSkillSection)

    \(xcodeProjectSkillSection)

    ## Skills

    Skills are discovered automatically from the legacy `~/.turbocode/SKILLS/**/SKILL.md`
    location and from Codex-compatible `.agents/skills/**/SKILL.md` folders in the
    workspace and user scope.
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

    Help the user design and install a reusable TurboCode skill. When a workspace
    is selected, create the skill at
    `.agents/skills/<skill-name>/SKILL.md` using `create_skill` when available;
    otherwise use `edit_file` to create the same workspace-relative path. The
    write must go through TurboCode's normal Review/Undo
    transaction; never claim the skill was saved until the tool succeeds. Without
    a workspace, return the complete file and explain that the user must choose a
    workspace before installation.

    A skill uses this format:

    ```markdown
    ---
    name: lowercase-kebab-name
    description: State precisely when the model should load these instructions
    ---
    # Skill Title

    Operational instructions, decision rules, examples, and relevant constraints.
    ```

    Keep the name under 64 characters and use lowercase letters, digits, and hyphens.
    Make the description specific enough for automatic selection and loading. Keep the body
    procedural and focused; avoid repeating general TurboCode behavior. When asked
    to create a skill, validate the name and description, create the directory and
    file when workspace tools are available, then report the exact path. TurboCode
    discovers valid files automatically before the next submitted prompt. The
    skill body should be self-contained; references to supporting workspace files
    must use paths that are clear from the active project. Keep the full file in
    the response only when the user asks for a draft or when the write cannot be
    performed.
    """

    // MARK: - Agent Tuning

    public func loadAgentTuning() throws -> AgentTuningConfig {
        guard FileManager.default.fileExists(atPath: agentTuningURL.path) else {
            return .default
        }
        do {
            let value = try JSONDecoder().decode(
                AgentTuningConfig.self,
                from: Data(contentsOf: agentTuningURL)
            )
            return try value.validated()
        } catch let error as AgentTuningError {
            throw error
        } catch let error as DecodingError {
            throw AgentTuningError.malformed(
                field: Self.decodingField(for: error),
                message: Self.decodingMessage(for: error)
            )
        }
    }

    public func saveAgentTuning(_ value: AgentTuningConfig) throws {
        let validated = try value.validated()
        try encoder.encode(validated).write(to: agentTuningURL, options: .atomic)
    }

    private func migrateAgentTuning() throws {
        if FileManager.default.fileExists(atPath: agentTuningURL.path) {
            let value = try loadAgentTuning()
            let rawData = try Data(contentsOf: agentTuningURL)
            let object = try? JSONSerialization.jsonObject(with: rawData)
                as? [String: Any]
            let hasCurrentSchema = object?["schemaVersion"] as? Int
                == AgentTuningConfig.currentSchemaVersion
            if !hasCurrentSchema {
                // Only a successfully decoded and validated configuration is
                // rewritten. Invalid files remain byte-for-byte recoverable.
                try saveAgentTuning(value)
            }
        } else {
            try saveAgentTuning(.default)
        }
    }

    private static func decodingField(for error: DecodingError) -> String {
        let codingPath: [CodingKey]
        switch error {
        case .keyNotFound(_, let context),
             .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .dataCorrupted(let context):
            codingPath = context.codingPath
        @unknown default:
            codingPath = []
        }
        let path = codingPath.map { $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? "config.json" : path
    }

    private static func decodingMessage(for error: DecodingError) -> String {
        switch error {
        case .keyNotFound(_, let context),
             .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return "The value could not be decoded."
        }
    }

    // MARK: - Remote Models

    public func loadRemoteModels() throws -> [RemoteModelConfig] {
        guard FileManager.default.fileExists(atPath: modelsURL.path) else { return [] }
        // PCC remains decodable so old configuration files stay readable, but
        // Apple's retired `fm serve` route must not re-enter the app through
        // persisted model metadata.
        return try JSONDecoder().decode([RemoteModelConfig].self, from: Data(contentsOf: modelsURL))
            .filter { !$0.isRetiredPCC }
    }

    /// Persists the complete model catalog after a Settings edit. Callers
    /// replace one entry in their in-memory snapshot first so unrelated model
    /// metadata and locally configured endpoints remain untouched.
    public func saveRemoteModels(_ models: [RemoteModelConfig]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let validated = try models.map { model in
            var model = model
            model.reasoningConfiguration = try model.reasoningConfiguration.validated()
            return model
        }
        try encoder.encode(validated).write(to: modelsURL, options: .atomic)
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

}

// MARK: - Remote Model Configuration

nonisolated public enum RemoteModelProvider: String, Codable, Hashable, Sendable {
    case openAICompatible
    case deepseek
}

nonisolated public enum RemoteModelRole: String, Codable, Hashable, Sendable {
    case local
    // PCC-RETIREMENT: remove after old models.json records no longer need decoding.
    case pcc
    case premium
}

nonisolated public enum RemoteReasoningTransport: String, Codable, Hashable, Sendable {
    case contextOptions
    case deepseekThinking
    case none
}

/// Declares which side owns reasoning intensity for an OpenAI-compatible
/// endpoint. This is explicit configuration: model names are never inspected
/// to infer a wire contract.
nonisolated public enum RemoteReasoningControlMode: String, Codable, Hashable, Sendable {
    case serverManaged
    case requestTokenBudget
}

/// Per-model request budgets used only when request-level control is enabled.
/// A nil maximum is encoded on the wire as the endpoint's unlimited sentinel.
nonisolated public struct RemoteReasoningConfiguration: Codable, Hashable, Sendable {
    public var mode: RemoteReasoningControlMode
    public var lowTokenBudget: Int
    public var mediumTokenBudget: Int
    public var highTokenBudget: Int
    public var maximumTokenBudget: Int?

    public init(
        mode: RemoteReasoningControlMode = .serverManaged,
        lowTokenBudget: Int = 512,
        mediumTokenBudget: Int = 2_048,
        highTokenBudget: Int = 8_192,
        maximumTokenBudget: Int? = nil
    ) {
        self.mode = mode
        self.lowTokenBudget = lowTokenBudget
        self.mediumTokenBudget = mediumTokenBudget
        self.highTokenBudget = highTokenBudget
        self.maximumTokenBudget = maximumTokenBudget
    }

    public static let serverManaged = RemoteReasoningConfiguration()
    public static let requestTokenBudget = RemoteReasoningConfiguration(
        mode: .requestTokenBudget
    )

    private enum CodingKeys: String, CodingKey {
        case mode, lowTokenBudget, mediumTokenBudget, highTokenBudget
        case maximumTokenBudget
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(RemoteReasoningControlMode.self, forKey: .mode)
            ?? .serverManaged
        lowTokenBudget = try values.decodeIfPresent(Int.self, forKey: .lowTokenBudget) ?? 512
        mediumTokenBudget = try values.decodeIfPresent(Int.self, forKey: .mediumTokenBudget)
            ?? 2_048
        highTokenBudget = try values.decodeIfPresent(Int.self, forKey: .highTokenBudget)
            ?? 8_192
        maximumTokenBudget = try values.decodeIfPresent(Int.self, forKey: .maximumTokenBudget)
    }

    func validated() throws -> Self {
        let namedBudgets = [
            ("lowTokenBudget", lowTokenBudget),
            ("mediumTokenBudget", mediumTokenBudget),
            ("highTokenBudget", highTokenBudget),
        ]
        for (name, value) in namedBudgets where !(1...1_048_576).contains(value) {
            throw RemoteReasoningConfigurationError.invalidBudget(name)
        }
        if let maximumTokenBudget,
           !(1...1_048_576).contains(maximumTokenBudget) {
            throw RemoteReasoningConfigurationError.invalidBudget("maximumTokenBudget")
        }
        return self
    }
}

nonisolated private enum RemoteReasoningConfigurationError: LocalizedError {
    case invalidBudget(String)

    var errorDescription: String? {
        switch self {
        case .invalidBudget(let field):
            "\(field) must be between 1 and 1,048,576 tokens."
        }
    }
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
    public var reasoningConfiguration: RemoteReasoningConfiguration
    public var supportsReasoning: Bool
    public var supportsGuidedGeneration: Bool
    public var contextWindowTokens: Int
    public var repositoryMap: RemoteRepositoryMapCapability
    public var credential: String?
    public var enabled: Bool

    /// Temporary compatibility gate for model records written before Apple
    /// disabled the PCC model behind `fm serve`.
    // PCC-RETIREMENT: remove this property together with `RemoteModelRole.pcc`.
    public var isRetiredPCC: Bool {
        role == .pcc || id == "apple-pcc"
    }

    public init(
        id: String,
        name: String,
        url: String,
        modelName: String,
        temperature: Double,
        provider: RemoteModelProvider = .openAICompatible,
        role: RemoteModelRole = .local,
        reasoningTransport: RemoteReasoningTransport = .contextOptions,
        reasoningConfiguration: RemoteReasoningConfiguration = .serverManaged,
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
        self.reasoningConfiguration = reasoningConfiguration
        self.supportsReasoning = supportsReasoning
        self.supportsGuidedGeneration = supportsGuidedGeneration
        self.contextWindowTokens = contextWindowTokens
        self.repositoryMap = repositoryMap
        self.credential = credential; self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, modelName, temperature, provider, role
        case reasoningTransport, reasoningConfiguration
        case supportsReasoning, supportsGuidedGeneration
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
        reasoningConfiguration = try values.decodeIfPresent(
            RemoteReasoningConfiguration.self,
            forKey: .reasoningConfiguration
        ) ?? .serverManaged
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
