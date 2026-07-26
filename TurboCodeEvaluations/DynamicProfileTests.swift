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
                dropsCompletedToolCalls: false
            ),
            history: [],
            events: ModelSessionEvents(
                toolStarted: { _, _ in },
                toolFinished: { _, _, _ in },
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
        #expect(!names.contains("toggle_skill"))
        #expect(!names.contains("load_agent_workflow"))
    }

    @Test("Llama and PCC receive capability-gated engineering workflows")
    func smallerRemoteModelsReceiveAgentWorkflows() throws {
        let pcc = try #require(RemoteModelConfig.defaults.first { $0.role == .pcc })

        #expect(ModelSessionFactory.usesAgentWorkflowSkills(
            backend: .llamaServer,
            remoteModel: .fallbackLlama
        ))
        #expect(ModelSessionFactory.usesAgentWorkflowSkills(
            backend: .foundationServe,
            remoteModel: pcc
        ))
        #expect(!ModelSessionFactory.usesAgentWorkflowSkills(
            backend: .premium,
            remoteModel: RemoteModelConfig.defaults.first { $0.role == .premium }
        ))

        let session = ModelSessionFactory.makeSession(
            configuration: makeConfiguration(profile: nil),
            history: [],
            events: inertEvents
        )
        let firstEntry = try #require(session.transcript.first)
        guard case .instructions(let instructions) = firstEntry else {
            Issue.record("Expected the Llama session to begin with instructions")
            return
        }
        let initialNames = Set(instructions.toolDefinitions.map(\.name))
        #expect(initialNames.contains("load_agent_workflow"))
        #expect(initialNames.contains("list_workspace"))
        #expect(initialNames.contains("read_file"))
        #expect(!initialNames.contains("edit_file"))
        #expect(!initialNames.contains("bash"))
        #expect(!initialNames.contains("xcode_project"))
    }

    @Test("Exclusive profiles do not gain an implicit workflow selector")
    func exclusiveProfilesDoNotReceiveAgentWorkflows() throws {
        let profile = UserDynamicProfile(
            name: "Reader only",
            baseModelID: .llama,
            toolIDs: [ToolCapabilityID.readFile.rawValue]
        )
        let session = ModelSessionFactory.makeSession(
            configuration: makeConfiguration(profile: profile),
            history: [],
            events: inertEvents
        )
        let firstEntry = try #require(session.transcript.first)
        guard case .instructions(let instructions) = firstEntry else {
            Issue.record("Expected the exclusive session to begin with instructions")
            return
        }

        #expect(instructions.toolDefinitions.map(\.name) == ["read_file"])
    }

    @Test("Agent workflows cover Xcode, SwiftPM, verification, and recovery")
    func agentWorkflowCatalogDefinesCompleteEngineeringLoops() throws {
        let descriptors = AgentWorkflowSkillCatalog.descriptors
        let names = Set(descriptors.map(\.name))
        let combined = descriptors.map(\.prompt).joined(separator: "\n")

        #expect(names == [
            "xcode-agent-loop",
            "swift-package-agent-loop",
            "diagnostic-recovery"
        ])
        #expect(combined.contains("xcode_project"))
        #expect(combined.contains("swift build"))
        #expect(combined.contains("swift test"))
        #expect(combined.contains("edit_file"))
        #expect(combined.contains("repeat the same verification"))
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

    @Test("A Swift package profile exposes exactly the initializer tool")
    func swiftPackageProfileCreatesOneInstance() {
        let profile = UserDynamicProfile(
            name: "Swift package initializer",
            baseModelID: .llama,
            toolIDs: [ToolCapabilityID.swiftPackageInit.rawValue]
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

        #expect(tools.map(\.name) == ["swift_package_init"])
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

    private var inertEvents: ModelSessionEvents {
        ModelSessionEvents(
            toolStarted: { _, _ in },
            toolFinished: { _, _, _ in },
            delegationChanged: { _ in }
        )
    }

    private func makeConfiguration(profile: UserDynamicProfile?) -> ModelSessionConfiguration {
        ModelSessionConfiguration(
            backend: profile?.baseModelID == .onDevice ? .foundationApple : .llamaServer,
            activeRemoteModel: profile?.baseModelID == .onDevice ? nil : .fallbackLlama,
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
            dropsCompletedToolCalls: true
        )
    }
}
