import Foundation

nonisolated struct DynamicProfileStore: Sendable {
    /// Version 3 records independently configurable worker slots. Versions 1
    /// and 2 remain readable; saving materializes their single-worker route
    /// without requiring a destructive migration pass.
    static let currentSchemaVersion = 3
    static let legacySchemaVersions: Set<Int> = [1, 2]

    private struct FileContents: Codable {
        let version: Int
        var profiles: [UserDynamicProfile]
    }

    let fileURL: URL

    @MainActor static var live: DynamicProfileStore {
        DynamicProfileStore(fileURL: TurboCodeConfig.shared.dynamicProfilesURL)
    }

    func load() throws -> [UserDynamicProfile] {
        let contents = try readContents()
        // PCC overrides remain decodable for migration safety, but must not
        // appear in the profile library after Apple's `fm serve` shutdown.
        // PCC-RETIREMENT: remove this filter when the legacy enum case goes.
        return contents.profiles.filter { $0.baseModelID != .pcc }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Migrates a valid legacy envelope without touching malformed or future
    /// files. This keeps user-authored profile data recoverable when a newer
    /// TurboCode version encounters a file it cannot safely interpret.
    func migrate() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let contents = try readContents()
        guard contents.version != Self.currentSchemaVersion else { return }
        try save(contents.profiles.map { try $0.validated() })
    }

    func save(_ profiles: [UserDynamicProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(
            FileContents(version: Self.currentSchemaVersion, profiles: profiles)
        )
            .write(to: fileURL, options: .atomic)
    }

    private func readContents() throws -> FileContents {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return FileContents(version: Self.currentSchemaVersion, profiles: [])
        }
        let contents = try JSONDecoder().decode(
            FileContents.self,
            from: Data(contentsOf: fileURL)
        )
        guard contents.version == Self.currentSchemaVersion
            || Self.legacySchemaVersions.contains(contents.version) else {
            throw DynamicProfileStoreError.unsupportedSchemaVersion(contents.version)
        }
        return contents
    }
}

nonisolated enum DynamicProfileStoreError: LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported profiles.json schema version: \(version)"
        }
    }
}
