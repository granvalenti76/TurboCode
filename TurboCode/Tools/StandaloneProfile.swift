import Foundation
import FoundationModels
import FoundationModelsUtilities

// MARK: - Standalone Profile

/// DynamicProfile for standalone mode with direct tools, disk-backed skills,
/// model selection, and reasoning level control.
nonisolated struct StandaloneProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let diskSkills: [TurboCodeSkillDefinition]
    let workspaceRoot: String
    let model: any LanguageModel
    let temperature: Double?
    let samplingMode: GenerationOptions.SamplingMode?
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let dropsCompletedToolCalls: Bool
    let executionPolicy: ExecutionPolicy
    let gitPolicy: GitPolicy
    let toolReceiptRegistry: ToolReceiptRegistry
    let toolPlan: ModelToolPlan
    let usesExclusiveToolSelection: Bool
    let supplementalTools: [any Tool]
    /// Created only when the experimental Safari gate is enabled. The
    /// prompt-based skill keeps activation content out of the cacheable prefix.
    let safariSkillActivations: SkillActivations?
    let onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)?
    let onToolEnd: (@Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void)?

    var body: some LanguageModelSession.DynamicProfile {
        if dropsCompletedToolCalls {
            configuredProfile.droppingCompletedToolCalls()
        } else {
            configuredProfile
        }
    }

    private var configuredProfile: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            if let safariSkillActivations {
                Skills(
                    activations: safariSkillActivations,
                    toolName: "activate_safari_skill",
                    skills: [SafariMCPFeature.skill]
                )
            }
            if usesExclusiveToolSelection {
                // Dynamic profiles are capability boundaries. Register the
                // resolved instances directly so no implicit capability can
                // appear outside the user's selection.
                supplementalTools
            } else {
                if !workspaceRoot.isEmpty {
                    // Tool policy lives in ModelSessionFactory's single
                    // instruction block. Keeping it out of this builder
                    // prevents Foundation Models from emitting a second
                    // system-prompt fragment for the same capability.
                    if toolPlan.contains(.readFile) {
                        ReadFileTool(
                            workspaceRoot: workspaceRoot,
                            executionPolicy: executionPolicy
                        )
                    }
                    if toolPlan.contains(.git) {
                        GitTool(
                            workspaceRoot: workspaceRoot,
                            policy: gitPolicy,
                            executionPolicy: executionPolicy,
                            receiptRegistry: toolReceiptRegistry
                        )
                    }
                    if toolPlan.contains(.bash) {
                        BashTool(workspaceRoot: workspaceRoot, executionPolicy: executionPolicy)
                    }
                    if toolPlan.contains(.swiftPackageManager) {
                        SwiftPackageManagerTool(
                            workspaceRoot: workspaceRoot,
                            executionPolicy: executionPolicy,
                            receiptRegistry: toolReceiptRegistry
                        )
                    }
                    if toolPlan.contains(.searchWorkspace) {
                        // Ripgrep is a default exploration primitive and stays
                        // directly available whenever the plan authorizes it.
                        RipgrepTool(
                            workspaceRoot: workspaceRoot,
                            executionPolicy: executionPolicy
                        )
                    }
                    if toolPlan.contains(.fileSystem) {
                        // Profiles authorize tools directly. Skills remain
                        // instruction packs and never alter runtime capability.
                        FileSystemTool(
                            workspaceRoot: workspaceRoot,
                            receiptRegistry: toolReceiptRegistry
                        )
                    }
                    if toolPlan.contains(.editFile) {
                        EditFileTool(
                            workspaceRoot: workspaceRoot,
                            receiptRegistry: toolReceiptRegistry
                        )
                    }
                }
                if toolPlan.contains(.loadSkill) {
                    LoadSkillTool(skills: diskSkills)
                }
                supplementalTools
            }
        }
        .model(model)
        .temperature(temperature)
        .samplingMode(samplingMode)
        .reasoningLevel(reasoningLevel)
        .onToolCall { call in
            if let action = onToolStart {
                await action(call)
            }
        }
        .onToolOutput { call, output in
            if let action = onToolEnd {
                await action(call, output)
            }
        }
    }
}
