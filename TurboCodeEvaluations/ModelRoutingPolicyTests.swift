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

        #expect(defaultPlan.registeredIDs == [.listWorkspace, .readFile, .writeOnDevice, .createSkill])
        #expect(explicitExpansion.registeredIDs == [.writeOnDevice, .readFile, .git, .bash, .delegateTask, .createSkill])
        #expect(defaultPlan.contains(.readFile))
        #expect(!defaultPlan.contains(.turboCodeGuide))
        #expect(!defaultPlan.contains(.git))
        #expect(!defaultPlan.contains(.editFile))
        #expect(!defaultPlan.contains(.delegateTask))
        #expect(!defaultPlan.contains(.callPowerfulModel))
    }

    @Test("Optional tools are default-off and available through explicit overrides")
    func optionalToolsRequireExplicitOverride() {
        let context = ToolAccessContext(
            hasWorkspace: true,
            hasSkills: true,
            hasDelegateModel: true,
            repositoryMapDetail: .enhanced
        )

        for profile in [
            ModelRuntimeProfile.microtask,
            .standalone,
            .orchestrator,
            .delegate
        ] {
            let defaultPlan = ModelToolCatalog.plan(
                profile: profile,
                tier: profile == .microtask ? .onDevice : .standard,
                context: context
            )
            #expect(!defaultPlan.contains(.turboCodeGuide))
            #expect(!defaultPlan.contains(.searchWorkspace))
            #expect(!defaultPlan.contains(.removeFile))

            let overridePlan = ModelToolCatalog.plan(
                profile: profile,
                tier: profile == .microtask ? .onDevice : .standard,
                context: context,
                selectedIDs: [.turboCodeGuide, .searchWorkspace, .removeFile]
            )
            #expect(overridePlan.contains(.turboCodeGuide))
            #expect(overridePlan.contains(.searchWorkspace))
            #expect(overridePlan.contains(.removeFile))
        }
    }

    @Test("Runtime prompt advertises Ripgrep instead of the persisted legacy ID")
    func promptUsesRipgrepRuntimeName() {
        let prompt = TurboCodeSystemPromptBuilder.build(
            TurboCodeSystemPromptContext(
                role: .standalone,
                backend: .llamaServer,
                workspaceRoot: "/tmp/workspace",
                agentTuning: AgentTuningConfig(),
                toolIDs: [.searchWorkspace],
                toolNames: [ToolCapabilityID.searchWorkspace.runtimeName],
                availableSkills: [],
                workspaceInstructions: nil
            )
        )

        #expect(prompt.contains("- ripgrep"))
        #expect(!prompt.contains("- grep\n"))
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

    @Test("Prompt explains accepted background delegation receipts")
    func promptGuidesBackgroundDelegation() {
        let tuning = AgentTuningConfig(
            orchestrator: OrchestratorPolicy(
                runsDelegatedTasksInBackground: true
            )
        )
        let prompt = TurboCodeSystemPromptBuilder.build(
            TurboCodeSystemPromptContext(
                role: .standalone,
                backend: .foundationApple,
                workspaceRoot: "/workspace",
                agentTuning: tuning,
                toolIDs: [.delegateTask],
                toolNames: ["delegate_task"],
                availableSkills: [],
                workspaceInstructions: nil
            )
        )

        #expect(prompt.contains("accepted delegate_task receipt"))
        #expect(prompt.contains("without waiting or polling"))
        #expect(prompt.contains("deliver the terminal result separately"))
    }

    @Test("Apple prompts receive their selected instruction-level reasoning policy")
    func applePromptIncludesReasoningPolicy() {
        let workspaceInstructions = WorkspaceInstructions(
            relativePath: "AGENTS.md",
            content: "Prefer focused tests.",
            revision: FileRevision.hash("Prefer focused tests.")
        )
        for (effort, expected) in [
            (ReasoningEffort.low, "shortest sound reasoning path"),
            (.medium, "identify the important steps"),
            (.high, "form a concrete plan"),
            (.xhigh, "Treat correctness as the primary objective")
        ] {
            let prompt = TurboCodeSystemPromptBuilder.build(
                TurboCodeSystemPromptContext(
                    role: .standalone,
                    backend: .foundationApple,
                    workspaceRoot: "/workspace",
                    agentTuning: .default,
                    toolIDs: [],
                    toolNames: [],
                    availableSkills: [],
                    workspaceInstructions: workspaceInstructions,
                    reasoningEffort: effort
                )
            )

            #expect(prompt.contains(expected))
            #expect(!prompt.contains("chain-of-thought transcript"))
            #expect(prompt.hasSuffix(
                "Follow this requirement together with all project instructions above."
            ))
            let projectEnd = prompt.range(of: "--- END AGENTS.md ---")
            let reminderStart = prompt.range(of: "Final reasoning requirement (")
            #expect(projectEnd != nil)
            #expect(reminderStart != nil)
            if let projectEnd, let reminderStart {
                #expect(projectEnd.lowerBound < reminderStart.lowerBound)
            }
        }
    }

    @Test("Remote providers do not receive prompt-level reasoning policy")
    func remotePromptsOmitReasoningPolicy() {
        for backend in [ModelBackend.llamaServer, .foundationServe, .premium, .codex] {
            let prompt = TurboCodeSystemPromptBuilder.build(
                TurboCodeSystemPromptContext(
                    role: .standalone,
                    backend: backend,
                    workspaceRoot: "/workspace",
                    agentTuning: .default,
                    toolIDs: [],
                    toolNames: [],
                    availableSkills: [],
                    workspaceInstructions: nil,
                    reasoningEffort: .xhigh
                )
            )

            #expect(!prompt.contains("Reasoning policy ("))
        }
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
