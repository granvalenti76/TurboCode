import Foundation
import Testing
@testable import TurboCode

@Suite("Model routing policy")
struct ModelRoutingPolicyTests {
    @Test("Selected runtime state deterministically assigns model roles")
    func selectedStateAssignsRoles() {
        let coordinator = UserDynamicProfile(
            name: "DeepSeek Coordinator",
            baseModelID: .deepseek,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )

        #expect(
            ModelRoutingPolicy.resolve(
                backend: .foundationApple,
                mode: .standalone,
                activeProfile: nil
            ).role == .microtaskOnDevice
        )
        #expect(
            ModelRoutingPolicy.resolve(
                backend: .llamaServer,
                mode: .standalone,
                activeProfile: nil
            ).role == .codingWorker
        )
        let powerful = ModelRoutingPolicy.resolve(
            backend: .premium,
            mode: .standalone,
            activeProfile: coordinator
        )
        #expect(powerful.role == .powerfulCoordinator)
        #expect(powerful.supportsStructuredDelegation)
        let llamaCoordinator = UserDynamicProfile(
            name: "Llama Coordinator",
            baseModelID: .llama,
            workerModelID: ProfileBaseModelID.pcc.rawValue,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let llamaPowerful = ModelRoutingPolicy.resolve(
            backend: .llamaServer,
            mode: .standalone,
            activeProfile: llamaCoordinator
        )
        #expect(llamaPowerful.role == .powerfulCoordinator)
        #expect(llamaPowerful.supportsStructuredDelegation)
        let onDeviceCoordinator = UserDynamicProfile(
            name: "On-device Coordinator",
            baseModelID: .onDevice,
            workerModelID: ProfileBaseModelID.llama.rawValue,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        let onDeviceRouting = ModelRoutingPolicy.resolve(
            backend: .foundationApple,
            mode: .standalone,
            activeProfile: onDeviceCoordinator
        )
        #expect(onDeviceRouting.role == .powerfulCoordinator)
        #expect(onDeviceRouting.supportsStructuredDelegation)
        let codexCoordinator = UserDynamicProfile(
            name: "Codex Coordinator",
            baseModelID: .codex,
            workerModelID: ProfileBaseModelID.llama.rawValue,
            toolIDs: [ToolCapabilityID.delegateTask.rawValue]
        )
        #expect(
            ModelRoutingPolicy.resolve(
                backend: .codex,
                mode: .standalone,
                activeProfile: codexCoordinator
            ).role == .powerfulCoordinator
        )
        #expect(
            ModelRoutingPolicy.resolve(
                backend: .foundationApple,
                mode: .orchestrator,
                activeProfile: nil
            ).role == .experimentalOnDeviceCoordinator
        )
    }

    @Test("Microtask profile exposes its default tool surface")
    func microtaskProfileHasDefaultToolSurface() {
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: true,
            hasDelegateModel: true,
            repositoryMapDetail: .enhanced
        )
        let defaultPlan = ModelToolCatalog.plan(
            profile: .microtask,
            tier: .onDevice,
            context: context
        )
        let explicitExpansion = ModelToolCatalog.plan(
            profile: .microtask,
            tier: .onDevice,
            context: context,
            selectedIDs: [
                .writeOnDevice, .readFile, .git, .bash, .delegateTask,
                .createSkill
            ]
        )

        #expect(defaultPlan.registeredIDs == [.turboCodeGuide, .listWorkspace, .readFile, .writeOnDevice, .createSkill])
        #expect(explicitExpansion.registeredIDs == [.writeOnDevice, .readFile, .git, .bash, .delegateTask, .createSkill])
        #expect(defaultPlan.contains(.readFile))
        #expect(!defaultPlan.contains(.git))
        #expect(!defaultPlan.contains(.editFile))
        #expect(!defaultPlan.contains(.delegateTask))
        #expect(!defaultPlan.contains(.callPowerfulModel))
    }

    @Test("Prompt does not impose the removed microtask competence barrier")
    func promptDoesNotImposeMicrotaskBarrier() {
        let prompt = TurboCodeSystemPromptBuilder.build(
            TurboCodeSystemPromptContext(
                role: .microtask,
                backend: .foundationApple,
                workspaceRoot: "/workspace",
                agentTuning: .default,
                toolIDs: [.writeOnDevice],
                toolNames: ["write_ondevice"],
                availableSkills: [],
                workspaceInstructions: nil
            )
        )

        #expect(!prompt.contains("On-device microtask role:"))
        #expect(!prompt.contains("Do not plan architecture"))
        #expect(!prompt.contains("select a coding-worker or powerful-coordinator profile"))
        #expect(prompt.contains("Use write_ondevice once with complete content"))
    }

    @Test("Prompt explains how an explicit delegate task capability is used")
    func promptGuidesExplicitDelegation() {
        let prompt = TurboCodeSystemPromptBuilder.build(
            TurboCodeSystemPromptContext(
                role: .standalone,
                backend: .foundationApple,
                workspaceRoot: "/workspace",
                agentTuning: .default,
                toolIDs: [.delegateTask],
                toolNames: ["delegate_task"],
                availableSkills: [],
                workspaceInstructions: nil
            )
        )

        #expect(prompt.contains("delegate_task is available"))
        #expect(prompt.contains("Do not claim the tool is unavailable"))
    }

    @Test("Legacy on-device coordinator is visibly experimental")
    func legacyCoordinatorIsExperimental() {
        #expect(
            OrchestratorMode.orchestrator.displayName
                == "On-Device (Experimental)"
        )
        #expect(OrchestratorMode.orchestrator.rawValue == "Orchestrator")
    }
}
