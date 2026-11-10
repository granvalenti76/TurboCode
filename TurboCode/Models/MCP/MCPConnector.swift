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
    /// Base name of a bundled `SKILL.md`-style file that teaches the app's
    /// working method, or `nil`. The skill is only offered through
    /// `load_skill` while the connector is enabled: the model loads it when a
    /// request matches, so a session that merely enabled the connector does
    /// not pay for the instructions.
    var skillResource: String? = nil
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
        // A copy of Prassitele's own blockout skill, adapted to connector
        // calls: the original drives the app with a script on the Mac, which
        // a TurboCode session, and a Studio session above all, cannot run.
        skillResource: "prassitele-sculpting"
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

    /// The skills the enabled connectors add to a session's `load_skill`
    /// catalog. A missing or malformed resource only removes that skill; the
    /// connector itself keeps working. Main-actor only because skill
    /// definitions are parsed there, like the user's own catalog.
    @MainActor
    static func skills(for connectors: [MCPConnector], bundle: Bundle = .main) -> [TurboCodeSkillDefinition] {
        connectors.compactMap { connector in
            guard let name = connector.skillResource else { return nil }
            if bundle == .main, let cached = bundledSkills[name] { return cached }
            guard let url = bundle.url(forResource: name, withExtension: "md")
                    ?? bundle.url(forResource: name, withExtension: "md", subdirectory: "ConnectorSkills"),
                  let skill = try? TurboCodeSkillDefinition(contentsOf: url) else { return nil }
            if bundle == .main { bundledSkills[name] = skill }
            return skill
        }
    }

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
        return all.map(\.id).filter(selection.contains)
    }
}
