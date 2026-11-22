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

/// Which saved prompt each profile uses. A missing entry means the built-in
/// TurboCode default.
nonisolated struct SystemPromptAssignments: Codable, Sendable, Hashable {
    var promptIDs: [SystemPromptProfile: UUID] = [:]
}

/// The documents a session configuration carries, already resolved from the
/// library so session assembly never touches the disk.
nonisolated struct ResolvedSystemPrompts: Sendable, Hashable {
    var coding: SystemPromptDocument = .turboCodeDefault
    var studio: SystemPromptDocument = .turboCodeDefault
    var delegate: SystemPromptDocument = .turboCodeDefault

    static let builtIn = ResolvedSystemPrompts()

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
            .filter { $0.pathExtension == "json" && $0 != assignmentsURL }
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
            delegate: document(.delegate)
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
