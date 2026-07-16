import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("First-launch bootstrap")
struct FirstLaunchBootstrapTests {
    @Test("A new home receives the complete TurboCode layout")
    func createsCompleteLayout() throws {
        let home = try makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".turbocode", isDirectory: true)
        let config = TurboCodeConfig(rootURL: root)

        #expect(!config.isOnboarded)
        try config.performOnboarding()

        #expect(config.isOnboarded)
        #expect(isDirectory(root.appendingPathComponent("sessions")))
        #expect(isDirectory(root.appendingPathComponent("SKILLS")))
        #expect(isDirectory(root.appendingPathComponent("diagnostics")))
        #expect(isDirectory(root.appendingPathComponent("cache/repository-maps")))
        #expect(isDirectory(root.appendingPathComponent("documentation/official")))
        #expect(isDirectory(root.appendingPathComponent("documentation/user")))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("models.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.json").path))
        #expect(try DynamicProfileStore(fileURL: config.dynamicProfilesURL).load().isEmpty)
        #expect(Set(config.loadSkills().map(\.name)) == ["skill-creator", "turbocode"])
    }

    @Test("Onboarding repairs missing additive paths without replacing user profiles")
    func repairsPartialLayout() throws {
        let home = try makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".turbocode", isDirectory: true)
        let config = TurboCodeConfig(rootURL: root)
        try config.performOnboarding()
        let profile = UserDynamicProfile(
            name: "Writer only",
            baseModelID: .onDevice,
            toolIDs: [ToolCapabilityID.writeOnDevice.rawValue]
        )
        try DynamicProfileStore(fileURL: config.dynamicProfilesURL).save([profile])
        try FileManager.default.removeItem(at: config.diagnosticsDirectoryURL)

        try config.performOnboarding()

        #expect(config.isOnboarded)
        #expect(try DynamicProfileStore(fileURL: config.dynamicProfilesURL).load() == [profile])
    }

    @Test("The Skills library loads all four built-in profiles without custom storage")
    func builtInProfilesAreAlwaysAvailable() throws {
        let home = try makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let viewModel = SkillsViewModel(
            store: DynamicProfileStore(fileURL: home.appendingPathComponent("profiles.json"))
        )

        let ids = viewModel.modelOptions(settings: SettingsStore()).map(\.id)

        #expect(ids == [.onDevice, .llama, .pcc, .deepseek])
    }

    private func makeEmptyHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-FirstLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isDirectory(_ url: URL) -> Bool {
        var value: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &value)
            && value.boolValue
    }
}
