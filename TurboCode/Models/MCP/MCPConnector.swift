import Foundation

/// A built-in bridge from a session to one named app on this Mac.
///
/// A connector is narrower than a tool that runs commands: the model can only
/// call the operations the other app publishes through MCP. It never gains a
/// shell or file access on the Mac through it, which is why a Studio session
/// may enable one without leaving the VM boundary described in PRODUCT.md.
nonisolated struct MCPConnector: Identifiable, Sendable, Hashable {
    /// Stable identifier persisted in `Conversation.connectors` and passed by
    /// the model to the `connector` tool. Never reuse one for another app.
    let id: String
    let name: String
    /// One user-facing sentence for the Connectors page.
    let summary: String
    /// Tells the model when the connector is the right tool for a request.
    let modelGuidance: String
    let systemImage: String
    let endpoint: MCPLoopbackEndpoint
    /// The session domains that may enable the connector.
    let domains: Set<SessionDomain>
    /// Shown when the app does not answer, so the user knows what to start.
    let startHint: String
    /// Bundled `SKILL.md`-style files that teach the app's working method.
    /// A skill is only offered through `load_skill` while the connector is
    /// enabled: the model loads it when a request matches, so a session that
    /// merely enabled the connector does not pay for the instructions.
    var skills: [MCPConnectorSkill] = []

    /// The skill files a session of `domain` receives, in declaration order.
    func skills(for domain: SessionDomain) -> [MCPConnectorSkill] {
        skills.filter { $0.domains.contains(domain) }
    }

    /// The skill names the connector can add, once each, for the Connectors page.
    var skillNames: [String] {
        skills.map(\.name).reduce(into: []) { names, name in
            if !names.contains(name) { names.append(name) }
        }
    }
}

/// One bundled skill file of a connector and the session domains it serves.
///
/// A skill may exist in one version per domain under the same `name`: a Coding
/// session runs on the Mac and may drive the app with bundled scripts through
/// Bash, while a Studio session must reach it only through the `connector`
/// tool, because its shell is inside the VM.
nonisolated struct MCPConnectorSkill: Sendable, Hashable {
    /// The skill name from the file's front matter, shown on the Connectors page.
    let name: String
    /// Base name of the `.md` file in the app bundle.
    let resource: String
    let domains: Set<SessionDomain>
}

/// An MCP endpoint served by an app on this Mac.
///
/// Only the loopback interface is representable. A connector must never send
/// a session's content to another machine, so there is no host to configure.
nonisolated struct MCPLoopbackEndpoint: Sendable, Hashable {
    let port: Int
    let path: String

    /// `nil` for a port or path that cannot name a local HTTP endpoint.
    init?(port: Int, path: String) {
        guard (1_024...65_535).contains(port), path.hasPrefix("/"),
              !path.contains("?"), !path.contains("#"), !path.contains("..") else { return nil }
        self.port = port
        self.path = path
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        // The initializer admits only values URLComponents can represent.
        return components.url!
    }
}

/// The connectors TurboCode ships. There is no user-defined connector: every
/// entry is reviewed here, with its endpoint and the domains it may serve.
nonisolated enum MCPConnectorCatalog {
    static let prassitele = MCPConnector(
        id: "prassitele",
        name: "Prassitele",
        summary: "Block out and adjust sculptures in the running Prassitele app.",
        modelGuidance: "Digital sculpting in the user's running Prassitele app: read the scene, add and transform parts, remesh, and shape regions.",
        systemImage: "cube.transparent",
        endpoint: MCPLoopbackEndpoint(port: 48_765, path: "/mcp")!,
        domains: [.coding, .cowork],
        startHint: "Open Prassitele and turn on Agent › Agent Server (MCP).",
        skills: [
            // Prassitele's head and torso skills, each in two versions. On the
            // Mac they keep their Python scripts (bundled next to them, one
            // Bash command per stage); in Studio the VM cannot reach the app,
            // so every part is one connector call. All four are adapted copies
            // of the skills in Prassitele's repository and can go stale.
            MCPConnectorSkill(name: "prassitele-sculpting", resource: "prassitele-sculpting", domains: [.coding]),
            MCPConnectorSkill(name: "prassitele-sculpting", resource: "prassitele-sculpting-studio", domains: [.cowork]),
            MCPConnectorSkill(name: "prassitele-torso", resource: "prassitele-torso", domains: [.coding]),
            MCPConnectorSkill(name: "prassitele-torso", resource: "prassitele-torso-studio", domains: [.cowork])
        ]
    )

    static let all: [MCPConnector] = [prassitele]

    static func connector(id: String) -> MCPConnector? {
        all.first { $0.id == id }
    }

    /// The connectors a session actually receives: the ones the user turned
    /// on, in catalog order, limited to those allowed in the session's domain.
    /// Unknown identifiers (from a newer or older build) are dropped.
    static func enabled(ids: [String], domain: SessionDomain) -> [MCPConnector] {
        all.filter { ids.contains($0.id) && $0.domains.contains(domain) }
    }

    /// The skills the enabled connectors add to a `domain` session's
    /// `load_skill` catalog. A missing or malformed resource only removes that
    /// skill; the connector itself keeps working. Main-actor only because
    /// skill definitions are parsed there, like the user's own catalog.
    @MainActor
    static func skills(
        for connectors: [MCPConnector],
        domain: SessionDomain,
        bundle: Bundle = .main
    ) -> [TurboCodeSkillDefinition] {
        connectors.flatMap { $0.skills(for: domain) }.compactMap { entry in
            let name = entry.resource
            if bundle == .main, let cached = bundledSkills[name] { return cached }
            guard let url = bundle.url(forResource: name, withExtension: "md")
                    ?? bundle.url(forResource: name, withExtension: "md", subdirectory: "ConnectorSkills"),
                  let parsed = try? TurboCodeSkillDefinition(contentsOf: url) else { return nil }
            // A skill that ships scripts names them through this placeholder:
            // they are bundled in the same folder as the file, which differs
            // between an installed app and a debug build.
            let skill = parsed.replacingInPrompt(
                skillDirectoryPlaceholder,
                with: url.deletingLastPathComponent().path
            )
            if bundle == .main { bundledSkills[name] = skill }
            return skill
        }
    }

    /// Replaced in a bundled skill with the folder that holds it.
    static let skillDirectoryPlaceholder = "{{SKILL_DIR}}"

    /// Bundled skills never change while the app runs, and the composer asks
    /// for the catalog while the user types, so each file is parsed once.
    @MainActor private static var bundledSkills: [String: TurboCodeSkillDefinition] = [:]

    /// `skills` joined to a session's own catalog. A skill the user installed
    /// under the same name wins, so a connector never replaces user content.
    @MainActor
    static func catalog(
        adding connectorSkills: [TurboCodeSkillDefinition],
        to skills: [TurboCodeSkillDefinition]
    ) -> [TurboCodeSkillDefinition] {
        skills + connectorSkills.filter { added in !skills.contains { $0.name == added.name } }
    }

    /// The identifiers to persist after the user flips one connector.
    static func ids(_ ids: [String], setting id: String, enabled: Bool) -> [String] {
        var selection = Set(ids)
        if enabled { selection.insert(id) } else { selection.remove(id) }
        // Catalog order keeps the stored value stable whatever the click order.
        // Identifiers outside the MCP catalog (the System Prompt Builder
        // switch shares this list) are kept after it, so toggling a
        // connector never turns another feature off.
        let catalogIDs = all.map(\.id)
        let others = ids.filter { !catalogIDs.contains($0) && selection.contains($0) }
        let added = catalogIDs.contains(id) || others.contains(id) || !enabled ? [] : [id]
        return catalogIDs.filter(selection.contains) + others + added
    }
}
