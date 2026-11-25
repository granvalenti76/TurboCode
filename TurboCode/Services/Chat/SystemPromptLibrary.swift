import Foundation

/// The session kinds that can each use their own system prompt, as listed in
/// the "Used by profiles" table of Settings › Agents › System Prompts.
///
/// Coding covers every host-workspace role (standalone, orchestrator, Codex).
/// Microtasks such as titles always keep TurboCode's default: they are
/// internal, and a user persona there would only cost tokens.
nonisolated enum SystemPromptProfile: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case coding
    case studio
    case delegate
}

/// A saved, user-owned system prompt.
nonisolated struct SystemPromptRecord: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var name: String
    /// Starts at 1 and grows by one whenever the document's content changes.
    /// Ratings are recorded per version, so a rename never bumps it.
    private(set) var version: Int
    /// True when the prompt began as a copy of TurboCode's default, which the
    /// editor shows as "from TurboCode default".
    let basedOnDefault: Bool
    private(set) var document: SystemPromptDocument
    private(set) var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        basedOnDefault: Bool,
        document: SystemPromptDocument,
        version: Int = 1,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.basedOnDefault = basedOnDefault
        self.document = document
        self.version = max(1, version)
        self.updatedAt = updatedAt
    }

    /// Replaces the content, bumping the version only for a real change so a
    /// save without edits keeps the ratings of the current version.
    mutating func updateDocument(_ newDocument: SystemPromptDocument, at date: Date = .now) {
        guard newDocument != document else { return }
        document = newDocument
        version += 1
        updatedAt = date
    }
}

/// One judgement of a saved prompt, given in a "Try" chat.
///
/// Ratings belong to a version, not to the prompt: an edit makes a new
/// prompt as far as the model is concerned, so old stars must not vouch for
/// it. The gallery shows the average of the current version only.
nonisolated struct SystemPromptRating: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let promptID: UUID
    let version: Int
    /// 1 to 5.
    let stars: Int
    let tags: [String]
    let note: String
    let date: Date
    /// The trial chat it came from, so the user can find the evidence.
    let conversationID: String?

    init(
        id: UUID = UUID(),
        promptID: UUID,
        version: Int,
        stars: Int,
        tags: [String] = [],
        note: String = "",
        date: Date = .now,
        conversationID: String? = nil
    ) {
        self.id = id
        self.promptID = promptID
        self.version = version
        self.stars = min(5, max(1, stars))
        self.tags = tags
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.date = date
        self.conversationID = conversationID
    }

    /// Quick reasons offered next to the stars. Fixed so they can be
    /// compared across prompts; the note covers everything else.
    static let suggestedTags = [
        "Follows the routine",
        "Right tone",
        "Too long",
        "Ignored a rule",
        "Used the wrong tools"
    ]
}

/// The average stars of one prompt version.
nonisolated struct SystemPromptRatingSummary: Sendable, Hashable {
    let average: Double
    let count: Int
}

/// Which saved prompt each profile uses. A missing entry means the built-in
/// TurboCode default.
nonisolated struct SystemPromptAssignments: Codable, Sendable, Hashable {
    var promptIDs: [SystemPromptProfile: UUID] = [:]
}

/// The agent's own name and sidebar icon, chosen in Settings › General.
///
/// The name reaches the model through the Identity area ("You are Ada…")
/// while the product keeps its name: About TurboCode, the window, and
/// notifications still say TurboCode, because they describe the app.
/// Stored with the prompts because, like them, it changes what the model
/// reads and must trigger the same single session rebuild.
nonisolated struct AgentIdentity: Codable, Sendable, Hashable {
    static let defaultName = "TurboCode"
    static let maximumNameLength = 32

    /// A small set of system colors keeps every choice legible on the
    /// sidebar in both appearances.
    enum Tint: String, Codable, Sendable, CaseIterable {
        case accent, blue, purple, pink, red, orange, green, teal, graphite
    }

    var name: String
    /// SF Symbol shown on a tile beside the name; nil shows the name alone,
    /// which is how the sidebar looked before the setting existed.
    var symbol: String?
    var tint: Tint

    init(name: String = AgentIdentity.defaultName, symbol: String? = nil, tint: Tint = .accent) {
        self.name = name
        self.symbol = symbol
        self.tint = tint
    }

    static let `default` = AgentIdentity()

    /// The name as used: one trimmed line, at most `maximumNameLength`
    /// characters, and the default when empty.
    var displayName: String {
        let line = name.components(separatedBy: .newlines).first ?? ""
        let trimmed = String(line.trimmingCharacters(in: .whitespaces).prefix(Self.maximumNameLength))
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultName : trimmed
    }

    /// Curated symbols that read well at sidebar size.
    static let symbolChoices = [
        "sparkles", "bolt.fill", "brain.head.profile", "cpu", "terminal.fill",
        "hammer.fill", "wand.and.stars", "leaf.fill", "flame.fill", "star.fill",
        "moon.stars.fill", "globe", "atom", "paintbrush.pointed.fill", "pawprint.fill"
    ]
}

/// The documents a session configuration carries, already resolved from the
/// library so session assembly never touches the disk.
nonisolated struct ResolvedSystemPrompts: Sendable, Hashable {
    var coding: SystemPromptDocument = .turboCodeDefault
    var studio: SystemPromptDocument = .turboCodeDefault
    var delegate: SystemPromptDocument = .turboCodeDefault
    /// The agent's name for the Identity area; see `AgentIdentity`.
    var agentName: String = AgentIdentity.defaultName

    static let builtIn = ResolvedSystemPrompts()

    /// The prompts of a "Try" chat: the trial document replaces the prompt
    /// of the chat's own kind of session (Coding or Studio) and nothing else.
    /// Delegates keep their profile's prompt, because the trial judges how
    /// the agent talks to the user, not how workers report back.
    func applyingTrial(_ document: SystemPromptDocument, domain: SessionDomain) -> Self {
        var copy = self
        switch domain {
        case .coding: copy.coding = document
        case .cowork: copy.studio = document
        }
        return copy
    }

    func document(for profile: SystemPromptProfile) -> SystemPromptDocument {
        switch profile {
        case .coding: coding
        case .studio: studio
        case .delegate: delegate
        }
    }

    /// The document for a builder role in a Coding (non-Studio) session.
    func document(forCodingRole role: TurboCodeSystemPromptRole) -> SystemPromptDocument {
        switch role {
        case .microtask: .turboCodeDefault
        case .delegate: delegate
        case .standalone, .orchestrator, .codex: coding
        }
    }
}

/// Stores saved prompts as one JSON file each in `~/.turbocode/prompts/`,
/// with the profile assignments in `assignments.json` beside them.
///
/// One file per prompt keeps a hand-edited or corrupt file from taking the
/// others down: unreadable files are skipped, and an assignment that points to
/// a missing prompt falls back to the built-in default instead of failing the
/// session. The built-in default is never written here, so it cannot be
/// deleted or edited.
nonisolated struct SystemPromptLibrary: Sendable {
    let directoryURL: URL

    static var live: SystemPromptLibrary {
        SystemPromptLibrary(directoryURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode/prompts", isDirectory: true))
    }

    private var assignmentsURL: URL {
        directoryURL.appendingPathComponent("assignments.json")
    }

    /// Kept apart from the prompt files so rating never rewrites a prompt
    /// and the record format stays unchanged.
    private var identityURL: URL {
        directoryURL.appendingPathComponent("identity.json")
    }

    private var ratingsURL: URL {
        directoryURL.appendingPathComponent("ratings.json")
    }

    private func recordURL(_ id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    /// Every readable saved prompt, ordered by name.
    func records() -> [SystemPromptRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = Self.decoder
        return files
            .filter { $0.pathExtension == "json" && $0 != assignmentsURL && $0 != ratingsURL && $0 != identityURL }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(SystemPromptRecord.self, from: data),
                      // A file renamed by hand must not shadow another prompt.
                      url.deletingPathExtension().lastPathComponent == record.id.uuidString
                else { return nil }
                return record
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func save(_ record: SystemPromptRecord) throws {
        try write(record, to: recordURL(record.id))
    }

    /// Deletes a prompt and drops any assignment to it, so the profiles that
    /// used it return to the built-in default.
    func delete(_ id: UUID) throws {
        var current = assignments()
        let before = current
        current.promptIDs = current.promptIDs.filter { $0.value != id }
        if current != before { try saveAssignments(current) }
        let kept = ratings().filter { $0.promptID != id }
        if kept.count != ratings().count { try write(kept, to: ratingsURL) }
        let url = recordURL(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func assignments() -> SystemPromptAssignments {
        guard let data = try? Data(contentsOf: assignmentsURL),
              let value = try? Self.decoder.decode(SystemPromptAssignments.self, from: data)
        else { return SystemPromptAssignments() }
        return value
    }

    func saveAssignments(_ value: SystemPromptAssignments) throws {
        try write(value, to: assignmentsURL)
    }

    /// The saved prompt a trial chat runs, or nil when it was deleted; the
    /// chat then falls back to its profile's prompt.
    func record(for trial: PromptTrial) -> SystemPromptRecord? {
        guard let id = UUID(uuidString: trial.promptID) else { return nil }
        return records().first { $0.id == id }
    }

    /// The saved identity, or the default when none was saved or the file
    /// is unreadable.
    func agentIdentity() -> AgentIdentity {
        guard let data = try? Data(contentsOf: identityURL),
              let value = try? Self.decoder.decode(AgentIdentity.self, from: data)
        else { return .default }
        return value
    }

    func saveAgentIdentity(_ value: AgentIdentity) throws {
        try write(value, to: identityURL)
    }

    /// Every rating, oldest first. An unreadable file reads as none, so a
    /// damaged ratings file never hides the prompts themselves.
    func ratings() -> [SystemPromptRating] {
        guard let data = try? Data(contentsOf: ratingsURL),
              let value = try? Self.decoder.decode([SystemPromptRating].self, from: data)
        else { return [] }
        return value
    }

    func addRating(_ rating: SystemPromptRating) throws {
        try write(ratings() + [rating], to: ratingsURL)
    }

    /// Average of the ratings given to exactly this version, or nil.
    func ratingSummary(for promptID: UUID, version: Int) -> SystemPromptRatingSummary? {
        Self.summary(of: ratings(), promptID: promptID, version: version)
    }

    static func summary(
        of ratings: [SystemPromptRating],
        promptID: UUID,
        version: Int
    ) -> SystemPromptRatingSummary? {
        let matching = ratings.filter { $0.promptID == promptID && $0.version == version }
        guard !matching.isEmpty else { return nil }
        let total = matching.reduce(0) { $0 + $1.stars }
        return SystemPromptRatingSummary(
            average: Double(total) / Double(matching.count),
            count: matching.count
        )
    }

    /// The document each profile uses right now.
    func resolved() -> ResolvedSystemPrompts {
        let byID = Dictionary(records().map { ($0.id, $0.document) }, uniquingKeysWith: { a, _ in a })
        let assigned = assignments().promptIDs
        func document(_ profile: SystemPromptProfile) -> SystemPromptDocument {
            assigned[profile].flatMap { byID[$0] } ?? .turboCodeDefault
        }
        return ResolvedSystemPrompts(
            coding: document(.coding),
            studio: document(.studio),
            delegate: document(.delegate),
            agentName: agentIdentity().displayName
        )
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
