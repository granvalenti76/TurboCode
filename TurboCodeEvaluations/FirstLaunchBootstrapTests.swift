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

    @Test("Onboarding migrates 0.1 configuration and profiles without changing their intent")
    func migratesLegacyConfigurationAndProfiles() throws {
        let home = try makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".turbocode", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = TurboCodeConfig(rootURL: root)

        var legacyConfig = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AgentTuningConfig.default)
        ) as! [String: Any]
        legacyConfig["schemaVersion"] = 0
        try JSONSerialization.data(withJSONObject: legacyConfig)
            .write(to: config.agentTuningConfigurationURL, options: .atomic)

        let legacyProfile = UserDynamicProfile(
            name: "Legacy local worker",
            baseModelID: .llama,
            toolIDs: [ToolCapabilityID.readFile.rawValue]
        )
        let profileObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacyProfile)
        )
        let legacyProfiles: [String: Any] = [
            "version": 1,
            "profiles": [profileObject]
        ]
        try JSONSerialization.data(withJSONObject: legacyProfiles)
            .write(to: config.dynamicProfilesURL, options: .atomic)

        try config.performOnboarding()

        let migratedTuning = try config.loadAgentTuning()
        let migratedProfilesValue = try DynamicProfileStore(
            fileURL: config.dynamicProfilesURL
        ).load()
        #expect(migratedTuning.schemaVersion == AgentTuningConfig.currentSchemaVersion)
        #expect(migratedProfilesValue == [legacyProfile])
        let migratedProfiles = try JSONSerialization.jsonObject(
            with: Data(contentsOf: config.dynamicProfilesURL)
        ) as! [String: Any]
        #expect(migratedProfiles["version"] as? Int == DynamicProfileStore.currentSchemaVersion)
    }

    @Test("Invalid configuration remains untouched and identifies the problematic field")
    func preservesInvalidConfigurationAndReportsField() throws {
        let home = try makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".turbocode", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = TurboCodeConfig(rootURL: root)
        let original = Data(
            "{\"execution\":{\"defaultCommandTimeoutSeconds\":1}}".utf8
        )
        try original.write(to: config.agentTuningConfigurationURL, options: .atomic)

        do {
            _ = try config.loadAgentTuning()
            Issue.record("Expected invalid configuration to be rejected")
        } catch let error as AgentTuningError {
            #expect(error.field == "execution.defaultCommandTimeoutSeconds")
            #expect(error.localizedDescription.contains("execution.defaultCommandTimeoutSeconds"))
        }

        let preserved = try Data(contentsOf: config.agentTuningConfigurationURL)
        #expect(preserved == original)
    }

    @Test("First launch without premium credentials keeps a coordinator and local worker available")
    func firstLaunchWithoutPremiumKeepsLocalDelegationAvailable() throws {
        let home = try makeEmptyHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".turbocode", isDirectory: true)
        let config = TurboCodeConfig(rootURL: root)
        try config.performOnboarding()

        let models = try config.loadRemoteModels()
        let deepSeek = try #require(models.first { $0.id == "deepseek" })
        let llama = try #require(models.first { $0.id == "llama" })
        #expect(deepSeek.credential == "deepseek")
        #expect(llama.credential == nil)

        let settings = SettingsStore()
        let viewModel = SkillsViewModel(store: DynamicProfileStore(fileURL: config.dynamicProfilesURL))
        #expect(viewModel.modelOption(for: .codex, settings: settings).isAvailable)
        #expect(viewModel.modelOption(for: .llama, settings: settings).isAvailable)

        let route = UserDynamicProfile(
            name: "Codex local worker",
            baseModelID: .codex,
            workerModelID: ProfileBaseModelID.llama.rawValue,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        try DynamicProfileStore(fileURL: config.dynamicProfilesURL).save([route])
        let loadedRoute = try #require(
            DynamicProfileStore(fileURL: config.dynamicProfilesURL).load().first
        )
        #expect(loadedRoute.isCoordinatorProfile)
        #expect(loadedRoute.resolvedWorkerModelID(fallback: "deepseek") == "llama")
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
