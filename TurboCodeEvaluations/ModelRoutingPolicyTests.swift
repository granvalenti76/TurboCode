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

    @Test("Microtask profile cannot add broad coding capabilities")
    func microtaskProfileHasNarrowToolSurface() {
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
        let attemptedExpansion = ModelToolCatalog.plan(
            profile: .microtask,
            tier: .onDevice,
            context: context,
            selectedIDs: [
                .writeOnDevice, .readFile, .git, .bash, .delegateTask
            ]
        )

        #expect(defaultPlan.registeredIDs == OnDeviceCapabilityPolicy.directToolIDs)
        #expect(attemptedExpansion.registeredIDs == [.writeOnDevice])
        #expect(!defaultPlan.contains(.git))
        #expect(!defaultPlan.contains(.editFile))
        #expect(!defaultPlan.contains(.callPowerfulModel))
    }

    @Test("Microtask prompt states the measured competence envelope")
    func microtaskPromptStatesBoundary() {
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

        #expect(prompt.contains("at most 30 lines"))
        #expect(prompt.contains("Do not plan architecture"))
        #expect(prompt.contains("select a coding-worker or powerful-coordinator profile"))
    }

    @Test("Explicit Swift micro-snippet remains eligible on-device")
    func explicitSnippetIsEligibleOnDevice() {
        let request = """
        Given this signature and context:
        func clamp(_ value: Int, minimum: Int, maximum: Int) -> Int
        Implement only the function body in at most 10 lines.
        """

        #expect(
            OnDeviceCapabilityPolicy.assignment(for: request)
                == .eligibleMicrotask
        )
    }

    @Test("Multi-file and architectural tasks never reach the microtask model")
    func broadTasksRequireCapableModel() {
        #expect(
            OnDeviceCapabilityPolicy.assignment(
                for: "Update Sources/App.swift and Tests/AppTests.swift."
            ) == .requiresCapableModel(.multiFile)
        )
        #expect(
            OnDeviceCapabilityPolicy.assignment(
                for: "Riprogetta l'architettura del progetto."
            ) == .requiresCapableModel(.architecture)
        )
        #expect(
            OnDeviceCapabilityPolicy.assignment(
                for: "Create two files for this feature."
            ) == .requiresCapableModel(.multiFile)
        )
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
