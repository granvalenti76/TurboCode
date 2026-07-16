import Foundation

nonisolated struct DynamicProfileStore: Sendable {
    private struct FileContents: Codable {
        let version: Int
        var profiles: [UserDynamicProfile]
    }

    let fileURL: URL

    @MainActor static var live: DynamicProfileStore {
        DynamicProfileStore(fileURL: TurboCodeConfig.shared.dynamicProfilesURL)
    }

    func load() throws -> [UserDynamicProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let contents = try JSONDecoder().decode(FileContents.self, from: Data(contentsOf: fileURL))
        return contents.profiles.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func save(_ profiles: [UserDynamicProfile]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(FileContents(version: 1, profiles: profiles))
            .write(to: fileURL, options: .atomic)
    }
}
