import Foundation
import FoundationModels
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

    @Test("Delegate Task enables delegation for supported custom profiles")
    func delegationProfileRequiresSupportedRoute() {
        let llamaCoordinator = UserDynamicProfile(
            name: "Llama Coordinator",
            baseModelID: .llama,
            workerModelID: ProfileBaseModelID.pcc.rawValue,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let deepSeekCoordinator = UserDynamicProfile(
            name: "Custom Orchestrator",
            baseModelID: .deepseek,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let codexCoordinator = UserDynamicProfile(
            name: "Codex Coordinator",
            baseModelID: .codex,
            workerModelID: ProfileBaseModelID.pcc.rawValue,
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
        #expect(llamaCoordinator.usesDelegation)
        #expect(deepSeekCoordinator.usesDelegation)
        #expect(codexCoordinator.usesDelegation)
        #expect(codexCoordinator.resolvedToolIDs.contains(.delegateTask))
        #expect(renamedOnDevice.usesDelegation)
        #expect(renamedOnDevice.resolvedToolIDs.contains(.delegateTask))
        #expect(!directDeepSeek.usesDelegation)
    }

    @Test("Custom profile model options include Codex")
    func customProfileModelsIncludeCodex() {
        let viewModel = SkillsViewModel()
        let options = viewModel.profileModelOptions(settings: SettingsStore())

        #expect(options.map(\.id) == ProfileBaseModelID.profileCases)
        #expect(options.contains(where: { $0.id == .codex && $0.isAvailable }))
    }

    @Test("Coordinator workers are persisted and legacy routes keep their fallback")
    func coordinatorWorkerSelectionMigrates() throws {
        let route = UserDynamicProfile(
            name: "Codex plus PCC",
            baseModelID: .codex,
            workerModelID: ProfileBaseModelID.pcc.rawValue,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let decoded = try JSONDecoder().decode(
            UserDynamicProfile.self,
            from: JSONEncoder().encode(route)
        )
        #expect(
            decoded.resolvedWorkerModelID(fallback: "llama")
                == ProfileBaseModelID.pcc.rawValue
        )

        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(route)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "workerModelID")
        let legacy = try JSONDecoder().decode(
            UserDynamicProfile.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(legacy.workerModelID == nil)
        #expect(legacy.resolvedWorkerModelID(fallback: "deepseek") == "deepseek")
    }

    @Test("Worker tool overrides persist and distinguish all from none")
    func workerToolSelectionRoundTrips() throws {
        let selected = UserDynamicProfile(
            name: "Focused worker",
            baseModelID: .onDevice,
            workerModelID: ProfileBaseModelID.llama.rawValue,
            workerToolIDs: [
                ToolCapabilityID.git.rawValue,
                ToolCapabilityID.readFile.rawValue,
                ToolCapabilityID.git.rawValue
            ],
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let decoded = try JSONDecoder().decode(
            UserDynamicProfile.self,
            from: JSONEncoder().encode(selected)
        )

        #expect(decoded.workerToolIDs == [
            ToolCapabilityID.git.rawValue,
            ToolCapabilityID.readFile.rawValue
        ])
        #expect(decoded.resolvedWorkerToolIDs == [.git, .readFile])

        let none = UserDynamicProfile(
            name: "Text-only worker",
            baseModelID: .onDevice,
            workerToolIDs: [],
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        #expect(none.resolvedWorkerToolIDs?.isEmpty == true)
        #expect(UserDynamicProfile(name: "Default worker", baseModelID: .onDevice)
            .resolvedWorkerToolIDs == nil)
    }

    @Test("Delegate tool plans honor an explicit worker allowlist")
    func delegateToolPlanUsesSelectedWorkerTools() {
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: true,
            hasDelegateModel: true,
            repositoryMapDetail: .compact
        )
        let plan = ModelToolCatalog.plan(
            profile: .delegate,
            tier: .standard,
            context: context,
            selectedIDs: [.git, .readFile]
        )

        #expect(plan.registeredIDs == [.git, .readFile])
        #expect(plan.assignment(for: .bash) == nil)
    }

    @Test("Codex coordinator configuration persists with legacy defaults")
    func codexCoordinatorConfigurationMigrates() throws {
        let route = UserDynamicProfile(
            name: "Codex precise route",
            baseModelID: .codex,
            workerModelID: ProfileBaseModelID.pcc.rawValue,
            codexModelID: "gpt-5.6-codex",
            codexReasoningEffort: .high,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let encoded = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(
            UserDynamicProfile.self,
            from: encoded
        )

        #expect(decoded.codexModelID == "gpt-5.6-codex")
        #expect(decoded.codexReasoningEffort == .high)

        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "codexModelID")
        object.removeValue(forKey: "codexReasoningEffort")
        let legacy = try JSONDecoder().decode(
            UserDynamicProfile.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        // Missing fields inherit the Codex composer defaults rather than
        // making a previously valid route undecodable or unusable.
        #expect(legacy.codexModelID == nil)
        #expect(legacy.codexReasoningEffort == nil)
        #expect(legacy.isCoordinatorProfile)
    }

    @Test("Execution role manages coordinator invariants atomically")
    func executionRoleOwnsManagedDelegationCapability() {
        var profile = UserDynamicProfile(
            name: "Focused Direct Profile",
            baseModelID: .onDevice,
            // Exercise repair of an explicit stale worker selection when the
            // compatibility execution-role helper enables delegation.
            workerModelID: "old-provider",
            greedyMode: true,
            toolIDs: [ToolCapabilityID.readFile.rawValue]
        )

        profile.setExecutionRole(.coordinatorWorker)

        #expect(profile.executionRole == .coordinatorWorker)
        #expect(profile.baseModelID == .onDevice)
        #expect(profile.workerModelID == ProfileBaseModelID.llama.rawValue)
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

    @Test("Execution role preserves an explicitly selected Codex coordinator")
    func executionRolePreservesCodexCoordinator() {
        var profile = UserDynamicProfile(
            name: "Codex route",
            baseModelID: .codex,
            workerModelID: ProfileBaseModelID.deepseek.rawValue
        )

        profile.setExecutionRole(.coordinatorWorker)

        #expect(profile.baseModelID == .codex)
        #expect(profile.workerModelID == ProfileBaseModelID.deepseek.rawValue)
        #expect(profile.isCoordinatorProfile)
    }

    @Test("Capability overrides expose delegation to supported coordinator models")
    func overrideOptionsScopeDelegationToCoordinatorModels() {
        let viewModel = SkillsViewModel()
        let settings = SettingsStore()

        #expect(
            viewModel.modelOption(for: .llama, settings: settings)
                .compatibleToolIDs.contains(.delegateTask)
        )
        #expect(
            viewModel.modelOption(for: .deepseek, settings: settings)
                .compatibleToolIDs.contains(.delegateTask)
        )
        #expect(
            viewModel.modelOption(for: .codex, settings: settings)
                .compatibleToolIDs.contains(.delegateTask)
        )
        #expect(
            viewModel.modelOption(for: .onDevice, settings: settings)
                .compatibleToolIDs.contains(.delegateTask)
        )
        #expect(
            !viewModel.modelOption(for: .pcc, settings: settings)
                .compatibleToolIDs.contains(.delegateTask)
        )
    }

    @Test("Selecting Delegate Task enables delegation and prepares a worker")
    func overrideCapabilitySelectionOwnsDelegationRoute() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DynamicProfileStore(
            fileURL: root.appendingPathComponent("profiles.json")
        )
        let profile = UserDynamicProfile(
            name: "Selectable coordinator",
            baseModelID: .llama,
            greedyMode: true,
            toolIDs: [ToolCapabilityID.readFile.rawValue]
        )
        try store.save([profile])
        let viewModel = SkillsViewModel(store: store)
        viewModel.reload()
        viewModel.select(.custom(profile.id))

        viewModel.setTool(.delegateTask, included: true)

        #expect(viewModel.draft?.usesDelegation == true)
        #expect(viewModel.draft?.workerModelID == ProfileBaseModelID.llama.rawValue)
        #expect(viewModel.draft?.greedyMode == false)
        #expect(viewModel.draft?.toolIDs.contains(ToolCapabilityID.delegateTask.rawValue) == true)

        viewModel.setTool(.delegateTask, included: false)

        // Removing the capability uses the same invariant-preserving route as
        // the Execution picker and leaves unrelated explicit tools untouched.
        #expect(viewModel.draft?.usesDelegation == false)
        #expect(viewModel.draft?.toolIDs.contains(ToolCapabilityID.delegateTask.rawValue) == false)
        #expect(viewModel.draft?.toolIDs.contains(ToolCapabilityID.readFile.rawValue) == true)
    }

    @Test("Profile validation repairs delegated sampling and worker invariants")
    func validationRepairsDelegatedProfileInvariants() throws {
        let blankWorker = UserDynamicProfile(
            name: "Blank worker",
            baseModelID: .llama,
            workerModelID: "   ",
            greedyMode: true,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let invalidWorker = UserDynamicProfile(
            name: "Removed worker",
            baseModelID: .llama,
            workerModelID: "old-provider",
            greedyMode: true,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )

        let blankResult = try blankWorker.validated()
        let invalidResult = try invalidWorker.validated()

        // Nil remains the compatibility signal for profiles that should use
        // the global worker preference, while an explicit stale ID is repaired
        // to the same default used when delegation is newly enabled.
        #expect(blankResult.workerModelID == nil)
        #expect(invalidResult.workerModelID == ProfileBaseModelID.llama.rawValue)
        #expect(!blankResult.greedyMode)
        #expect(!invalidResult.greedyMode)
    }

    @Test("Changing a worker does not perturb the DeepSeek coordinator tool prefix")
    func deepSeekCoordinatorToolPrefixStaysCacheStable() {
        let llamaRoute = UserDynamicProfile(
            name: "DeepSeek Coordinator",
            baseModelID: .deepseek,
            workerModelID: ProfileBaseModelID.llama.rawValue,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let pccRoute = UserDynamicProfile(
            name: "DeepSeek Coordinator",
            baseModelID: .deepseek,
            workerModelID: ProfileBaseModelID.pcc.rawValue,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: false,
            hasDelegateModel: true,
            repositoryMapDetail: .enhanced
        )

        let llamaPlan = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .enhanced,
            context: context,
            selectedIDs: llamaRoute.resolvedToolIDs
        )
        let pccPlan = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .enhanced,
            context: context,
            selectedIDs: pccRoute.resolvedToolIDs
        )

        // Worker choice is runtime invocation state. It must not alter the
        // DeepSeek coordinator's leading tool definition or trigger cache miss.
        #expect(llamaPlan.registeredIDs == [.delegateTask])
        #expect(pccPlan.registeredIDs == llamaPlan.registeredIDs)
    }

    @Test("Profile option families enforce supported coordinator routes")
    func profileOptionFamiliesAreScoped() {
        #expect(ProfileBaseModelID.builtInCases == [.onDevice, .llama, .pcc, .deepseek])
        #expect(ProfileBaseModelID.coordinatorCases == [.onDevice, .llama, .deepseek, .codex])
        #expect(ProfileBaseModelID.workerCases == [.pcc, .llama, .deepseek])
        #expect(!ProfileBaseModelID.workerCases.contains(.codex))
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

    @Test("Persisted grep capability resolves to the Ripgrep replacement")
    func persistedGrepCapabilityUsesRipgrepRuntimeName() {
        let profile = UserDynamicProfile(
            name: "Search only",
            baseModelID: .llama,
            // `grep` is the historical persisted capability value. Runtime
            // replacement must not require rewriting an existing profile.
            toolIDs: ["grep"]
        )
        let plan = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .standard,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: false,
                hasDelegateModel: false,
                repositoryMapDetail: .compact
            ),
            selectedIDs: profile.resolvedToolIDs
        )

        let tools = ModelSessionFactory.toolInstances(
            for: plan,
            configuration: makeConfiguration(profile: profile)
        )

        #expect(profile.resolvedToolIDs == [.searchWorkspace])
        #expect(tools.map(\.name) == ["ripgrep"])
        #expect(ToolCapabilityID.searchWorkspace.rawValue == "grep")
        #expect(ToolCapabilityID.searchWorkspace.runtimeName == "ripgrep")
    }

    @Test("DeepSeek keeps its selected tools directly available")
    func deepSeekUsesDirectToolDefinitions() throws {
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
                reasoningLevel: .deep,
                delegateReasoningLevel: nil,
                activeTemperature: nil,
                delegateTemperature: nil,
                delegateToolIDs: nil,
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
        #expect(names.contains("ripgrep"))
        #expect(names.contains("swift_package_manager"))
        #expect(!names.contains("toggle_skill"))
        // DeepSeek depends on a fixed direct tool surface so otherwise equal
        // turns retain the same cacheable leading request prefix.
        #expect(Set(names).count == names.count)
    }

    @Test("Llama tool definitions keep their order across profile rebuilds")
    func llamaToolDefinitionOrderIsStable() throws {
        let firstBuiltIn = try llamaToolNames(profile: nil)
        let secondBuiltIn = try llamaToolNames(profile: nil)

        #expect(firstBuiltIn == secondBuiltIn)
        #expect(Set(firstBuiltIn).count == firstBuiltIn.count)

        let override = UserDynamicProfile(
            name: "Cache-stable Llama",
            baseModelID: .llama,
            // Deliberately avoid catalog order: selected sets must still resolve
            // through ToolCapabilityID.allCases before tools reach the wire.
            toolIDs: [
                ToolCapabilityID.editFile.rawValue,
                ToolCapabilityID.git.rawValue,
                ToolCapabilityID.readFile.rawValue,
                ToolCapabilityID.listWorkspace.rawValue,
            ]
        )
        let firstOverride = try llamaToolNames(profile: override)
        let secondOverride = try llamaToolNames(profile: override)

        #expect(firstOverride == secondOverride)
        #expect(firstOverride == ["list_workspace", "read_file", "git", "edit_file"])
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

    @Test("Built-in Llama exposes file operations without skill activation")
    func llamaUsesDirectFileSystemTool() throws {
        let names = try llamaToolNames(profile: nil)

        #expect(names.contains("file_system"))
        #expect(!names.contains("toggle_skill"))
        #expect(!names.contains("activate_skill"))
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-DynamicProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func llamaToolNames(profile: UserDynamicProfile?) throws -> [String] {
        let session = ModelSessionFactory.makeSession(
            configuration: ModelSessionConfiguration(
                backend: .llamaServer,
                activeRemoteModel: .fallbackLlama,
                delegateRemoteModel: .fallbackLlama,
                orchestratorMode: .standalone,
                workspaceRoot: "/tmp/workspace",
                agentTuning: .default,
                availableSkills: [],
                activeDynamicProfile: profile,
                reasoningLevel: nil,
                delegateReasoningLevel: nil,
                activeTemperature: nil,
                delegateTemperature: nil,
                delegateToolIDs: nil,
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
            Issue.record("Expected the Llama session to begin with instructions")
            return []
        }
        return instructions.toolDefinitions.map(\.name)
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
            reasoningLevel: nil,
            delegateReasoningLevel: nil,
            activeTemperature: nil,
            delegateTemperature: nil,
            delegateToolIDs: profile.resolvedWorkerToolIDs,
            dropsCompletedToolCalls: true,
            workspaceInstructions: nil
        )
    }
}
