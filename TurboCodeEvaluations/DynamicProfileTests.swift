import Foundation
import FoundationModels
import FoundationModelsUtilities
import Testing
@testable import TurboCode

@MainActor
@Suite("Dynamic profiles")
struct DynamicProfileTests {
    @Test("Persists explicit tools and skills")
    func roundTripsProfile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DynamicProfileStore(fileURL: root.appendingPathComponent("profiles.json"))
        let profile = UserDynamicProfile(
            name: "GitHub PR Assistant",
            summary: "Handles pull requests",
            baseModelID: .pcc,
            greedyMode: true,
            toolIDs: ["git", "read_file", "git"],
            skillIDs: ["pull-request-review"]
        )

        try store.save([profile])
        let loaded = try #require(store.load().first)

        #expect(loaded == profile)
        #expect(loaded.greedyMode)
        #expect(loaded.toolIDs == ["git", "read_file"])
        #expect(loaded.resolvedToolIDs.contains(.loadSkill))
    }

    @Test("Legacy profiles default greedy mode to off")
    func legacyProfileDefaultsGreedyModeToOff() throws {
        let profile = UserDynamicProfile(name: "Legacy", baseModelID: .llama)
        let encoded = try JSONEncoder().encode(profile)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "greedyMode")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(UserDynamicProfile.self, from: legacyData)

        #expect(!decoded.greedyMode)
    }

    @Test("Greedy custom profiles select greedy sampling")
    func greedyProfileSelectsGreedySampling() throws {
        let profile = UserDynamicProfile(
            name: "Deterministic",
            baseModelID: .llama,
            greedyMode: true
        )

        let mode = try #require(ModelSessionFactory.profileSamplingMode(profile))

        #expect(mode.kind == .greedy)
        #expect(ModelSessionFactory.profileSamplingMode(nil) == nil)
        #expect(ModelSessionFactory.profileSamplingMode(UserDynamicProfile(
            name: "DeepSeek",
            baseModelID: .deepseek,
            greedyMode: true
        )) == nil)
    }

    @Test("An empty profile exposes no capabilities")
    func emptyProfileIsExclusive() {
        let profile = UserDynamicProfile(name: "Focused", baseModelID: .onDevice)

        #expect(profile.resolvedToolIDs.isEmpty)
        #expect(profile.skillIDs.isEmpty)
    }

    @Test("Only DeepSeek with typed delegation is a coordinator profile")
    func coordinatorProfileRequiresSupportedRoute() {
        let coordinator = UserDynamicProfile(
            name: "Custom Orchestrator",
            baseModelID: .deepseek,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let renamedOnDevice = UserDynamicProfile(
            name: "Custom Orchestrator",
            baseModelID: .onDevice,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let directDeepSeek = UserDynamicProfile(
            name: "DeepSeek Direct",
            baseModelID: .deepseek
        )

        // Product semantics come from model plus capability, never the
        // user-editable display name.
        #expect(coordinator.isCoordinatorProfile)
        #expect(!renamedOnDevice.isCoordinatorProfile)
        #expect(!renamedOnDevice.resolvedToolIDs.contains(.delegateTask))
        #expect(!directDeepSeek.isCoordinatorProfile)
    }

    @Test("Execution role manages coordinator invariants atomically")
    func executionRoleOwnsManagedDelegationCapability() {
        var profile = UserDynamicProfile(
            name: "Focused Direct Profile",
            baseModelID: .onDevice,
            greedyMode: true,
            toolIDs: [ToolCapabilityID.readFile.rawValue]
        )

        profile.setExecutionRole(.coordinatorWorker)

        #expect(profile.executionRole == .coordinatorWorker)
        #expect(profile.baseModelID == .deepseek)
        #expect(!profile.greedyMode)
        #expect(profile.resolvedToolIDs.contains(.delegateTask))
        #expect(profile.resolvedToolIDs.contains(.readFile))

        profile.setExecutionRole(.direct)

        // Returning to direct execution removes only the system-managed route;
        // the user's advanced capability composition remains intact.
        #expect(profile.executionRole == .direct)
        #expect(!profile.resolvedToolIDs.contains(.delegateTask))
        #expect(profile.resolvedToolIDs.contains(.readFile))
    }

    @Test("Selected skills implicitly expose only the skill loader")
    func skillsEnableLoader() {
        let profile = UserDynamicProfile(
            name: "PR Review",
            baseModelID: .pcc,
            toolIDs: [ToolCapabilityID.git.rawValue],
            skillIDs: ["pull-request-review"]
        )

        #expect(profile.resolvedToolIDs == [.git, .loadSkill])
    }

    @Test("A custom plan registers only explicitly selected compatible tools")
    func customToolPlanIsExclusive() {
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: false,
            hasDelegateModel: false,
            repositoryMapDetail: nil
        )
        let plan = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .onDevice,
            context: context,
            selectedIDs: [.writeOnDevice, .git, .swiftWorkspaceMap, .xcodeProject]
        )

        #expect(plan.registeredIDs == [.writeOnDevice, .git])
        #expect(!StandaloneSkills.isEnabled(for: plan))
    }

    @Test("A one-tool dynamic profile creates exactly one runtime tool")
    func oneToolProfileCreatesOneInstance() {
        let profile = UserDynamicProfile(
            name: "Writer only",
            baseModelID: .onDevice,
            toolIDs: [ToolCapabilityID.writeOnDevice.rawValue]
        )
        let plan = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .onDevice,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: false,
                hasDelegateModel: false,
                repositoryMapDetail: nil
            ),
            selectedIDs: profile.resolvedToolIDs
        )
        let configuration = makeConfiguration(profile: profile)

        let tools = ModelSessionFactory.toolInstances(
            for: plan,
            configuration: configuration
        )

        #expect(tools.map(\.name) == ["write_ondevice"])
    }

    @Test("DeepSeek keeps skill-backed tools directly available")
    func deepSeekUsesCacheStableToolDefinitions() throws {
        let deepSeek = try #require(RemoteModelConfig.defaults.first { $0.id == "deepseek" })
        let session = ModelSessionFactory.makeSession(
            configuration: ModelSessionConfiguration(
                backend: .premium,
                activeRemoteModel: deepSeek,
                delegateRemoteModel: .fallbackLlama,
                orchestratorMode: .standalone,
                workspaceRoot: "/tmp/workspace",
                agentTuning: .default,
                availableSkills: [],
                activeDynamicProfile: nil,
                skillActivations: SkillActivations(),
                reasoningLevel: .deep,
                delegateReasoningLevel: nil,
                activeTemperature: nil,
                delegateTemperature: nil,
                dropsCompletedToolCalls: false,
                workspaceInstructions: nil
            ),
            history: [],
            events: ModelSessionEvents(
                toolStarted: { _, _, _ in },
                toolFinished: { _, _, _, _ in },
                delegationChanged: { _ in }
            )
        )

        let firstEntry = try #require(session.transcript.first)
        guard case .instructions(let instructions) = firstEntry else {
            Issue.record("Expected the session to begin with instructions")
            return
        }
        let names = instructions.toolDefinitions.map { $0.name }
        #expect(names.contains("file_system"))
        #expect(names.contains("grep"))
        #expect(names.contains("swift_package_manager"))
        #expect(!names.contains("toggle_skill"))
        // DeepSeek depends on a fixed direct tool surface; skill activation
        // would change the leading request prefix between otherwise equal turns.
        #expect(Set(names).count == names.count)
    }

    @Test("A remove-only profile exposes exactly the flat removal tool")
    func removeOnlyProfileCreatesOneInstance() {
        let profile = UserDynamicProfile(
            name: "Remover only",
            baseModelID: .onDevice,
            toolIDs: [ToolCapabilityID.removeFile.rawValue]
        )
        let plan = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .onDevice,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: false,
                hasDelegateModel: false,
                repositoryMapDetail: nil
            ),
            selectedIDs: profile.resolvedToolIDs
        )

        let tools = ModelSessionFactory.toolInstances(
            for: plan,
            configuration: makeConfiguration(profile: profile)
        )

        #expect(tools.map(\.name) == ["remove_file"])
    }

    @Test("A Swift package profile exposes exactly the unified manager tool")
    func swiftPackageProfileCreatesOneInstance() {
        let profile = UserDynamicProfile(
            name: "Swift package manager",
            baseModelID: .llama,
            toolIDs: [ToolCapabilityID.swiftPackageManager.rawValue]
        )
        let plan = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .standard,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: false,
                hasDelegateModel: false,
                repositoryMapDetail: nil
            ),
            selectedIDs: profile.resolvedToolIDs
        )

        let tools = ModelSessionFactory.toolInstances(
            for: plan,
            configuration: makeConfiguration(profile: profile)
        )

        #expect(tools.map(\.name) == ["swift_package_manager"])
    }

    @Test("Legacy Swift package initializer profiles migrate to the unified manager")
    func legacySwiftPackageCapabilityMigrates() {
        let profile = UserDynamicProfile(
            name: "Legacy SwiftPM",
            baseModelID: .pcc,
            toolIDs: ["swift_package_init"]
        )

        #expect(profile.resolvedToolIDs == [.swiftPackageManager])
    }

    @Test("Every native and remote model tier receives Swift Package Manager")
    func swiftPackageManagerIsAvailableAcrossModelTiers() {
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: false,
            hasDelegateModel: false,
            repositoryMapDetail: .compact
        )

        for tier in [ModelToolTier.onDevice, .standard, .enhanced] {
            let plan = ModelToolCatalog.plan(
                profile: .standalone,
                tier: tier,
                context: context
            )
            #expect(plan.contains(.swiftPackageManager))
        }
    }

    @Test("File operations stay a direct tool in an exclusive profile")
    func fileOperationsDoNotAddSkillActivator() {
        let profile = UserDynamicProfile(
            name: "Files only",
            baseModelID: .llama,
            toolIDs: [ToolCapabilityID.fileSystem.rawValue]
        )
        let plan = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .standard,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: false,
                hasDelegateModel: false,
                repositoryMapDetail: nil
            ),
            selectedIDs: profile.resolvedToolIDs
        )

        let tools = ModelSessionFactory.toolInstances(
            for: plan,
            configuration: makeConfiguration(profile: profile)
        )

        #expect(tools.map(\.name) == ["file_system"])
    }

    @Test("Native skill activation is registered only for skill-backed tools")
    func nativeSkillsRequireSkillBackedTool() {
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: false,
            hasDelegateModel: false,
            repositoryMapDetail: nil
        )
        let plan = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .standard,
            context: context,
            selectedIDs: [.fileSystem]
        )

        #expect(StandaloneSkills.isEnabled(for: plan))
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-DynamicProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeConfiguration(profile: UserDynamicProfile) -> ModelSessionConfiguration {
        ModelSessionConfiguration(
            backend: profile.baseModelID == .onDevice ? .foundationApple : .llamaServer,
            activeRemoteModel: profile.baseModelID == .onDevice ? nil : .fallbackLlama,
            delegateRemoteModel: .fallbackLlama,
            orchestratorMode: .standalone,
            workspaceRoot: "/tmp/workspace",
            agentTuning: .default,
            availableSkills: [],
            activeDynamicProfile: profile,
            skillActivations: SkillActivations(),
            reasoningLevel: nil,
            delegateReasoningLevel: nil,
            activeTemperature: nil,
            delegateTemperature: nil,
            dropsCompletedToolCalls: true,
            workspaceInstructions: nil
        )
    }
}
