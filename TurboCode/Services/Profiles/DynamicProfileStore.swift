import Foundation

nonisolated struct DynamicProfileStore: Sendable {
    /// Version 2 records the coordinator/worker profile fields introduced in
    /// M4.3. Version 1 remains readable so existing 0.1.0 profiles can be
    /// upgraded atomically during onboarding.
    static let currentSchemaVersion = 2
    static let legacySchemaVersions: Set<Int> = [1]

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
        return contents.profiles.sorted {
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
        try save(contents.profiles)
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
