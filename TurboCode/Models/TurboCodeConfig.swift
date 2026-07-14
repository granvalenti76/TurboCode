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
    private var sessionsDir: URL { rootURL.appendingPathComponent("sessions") }
    public var skillsDirectoryURL: URL { rootURL.appendingPathComponent("SKILLS", isDirectory: true) }

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
    }

    public func performOnboarding() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillsDirectoryURL, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: modelsURL.path) {
            let defaultModels: [RemoteModelConfig] = [
                RemoteModelConfig(id: "llama", name: "Llama-server",
                    url: "http://127.0.0.1:8080/v1",
                    modelName: "/Users/granvalenti/.modelli/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
                    temperature: 0.6),
                RemoteModelConfig(id: "apple-pcc", name: "Apple PCC",
                    url: "http://127.0.0.1:1976/v1",
                    modelName: "pcc", temperature: 0.6),
            ]
            try encoder.encode(defaultModels).write(to: modelsURL, options: .atomic)
        }

        try installBuiltInSkill(name: "turbocode", contents: Self.turboCodeSkill)
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

    private static let turboCodeSkill = """
    ---
    name: turbocode
    description: Explain TurboCode, its model modes, workspace tools, approvals, skills, and interface behavior
    ---
    # TurboCode

    TurboCode is a native macOS coding assistant built with SwiftUI. Always identify
    yourself as TurboCode, never as an Apple product or as the underlying model.

    ## Model modes

    - Standalone gives the selected model direct access to workspace tools.
    - Orchestrator uses the Apple on-device model to coordinate work and delegates
      complex coding tasks to the configured powerful model.
    - Available backends can include Foundation Apple, Apple PCC, and Llama-server.

    ## Workspace tools

    - `read_file` reads complete files or focused numbered line ranges.
    - `grep` searches workspace text.
    - `file_system` lists and manages files inside the workspace.
    - `bash` runs bounded commands with read-only workspace access in a macOS process sandbox.
    - `apply_edits` accepts revision-bound line operations, creates an internal Git
      patch, and presents a review widget with additions, deletions, Review, and Undo.
    - Text creation and editing run automatically. Only file or directory deletion
      asks for approval.

    TurboCode never removes project files when a workspace is removed from the
    sidebar. It removes only the workspace reference and associated chat sessions.

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

    // MARK: - Remote Models

    public func loadRemoteModels() throws -> [RemoteModelConfig] {
        guard FileManager.default.fileExists(atPath: modelsURL.path) else { return [] }
        return try JSONDecoder().decode([RemoteModelConfig].self, from: Data(contentsOf: modelsURL))
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

public struct RemoteModelConfig: Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var url: String
    public var modelName: String
    public var temperature: Double

    public init(id: String, name: String, url: String, modelName: String, temperature: Double) {
        self.id = id; self.name = name; self.url = url
        self.modelName = modelName; self.temperature = temperature
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

    public init(id: String = UUID().uuidString, kind: String, text: String,
                createdAt: Date = .now, model: String? = nil, providerId: String? = nil,
                diffPatch: DiffPatchBlock? = nil) {
        self.id = id; self.kind = kind; self.text = text
        self.createdAt = createdAt; self.model = model; self.providerId = providerId
        self.diffPatch = diffPatch
    }
}
