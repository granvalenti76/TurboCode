import Foundation
import FoundationModels
import FoundationModelsUtilities

// MARK: - Standalone Profile

/// DynamicProfile for standalone mode with Skills, model selection,
/// and reasoning level control.
struct StandaloneProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let activations: SkillActivations
    let diskSkills: [TurboCodeSkillDefinition]
    let workspaceRoot: String
    let model: any LanguageModel
    let temperature: Double?
    let samplingMode: GenerationOptions.SamplingMode?
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let dropsCompletedToolCalls: Bool
    let usesCacheStableToolDefinitions: Bool
    let usesAgentWorkflowSkills: Bool
    let executionPolicy: ExecutionPolicy
    let gitPolicy: GitPolicy
    let toolPlan: ModelToolPlan
    let usesExclusiveToolSelection: Bool
    let supplementalTools: [any Tool]
    let agentWorkflowTools: [any Tool]
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
            if usesAgentWorkflowSkills {
                // Llama/PCC initially see one selector; engineering schemas
                // enter the profile only with the chosen loop.
                AgentWorkflowSkills(
                    activations: activations,
                    tools: agentWorkflowTools
                )
            }
            if usesExclusiveToolSelection {
                // Dynamic profiles are capability boundaries. Register the
                // resolved instances directly so FoundationModelsUtilities
                // cannot add activation tools or other implicit capabilities.
                supplementalTools
            } else {
                if !workspaceRoot.isEmpty, !usesAgentWorkflowSkills {
                    // Tool policy lives in ModelSessionFactory's single
                    // instruction block. Keeping it out of this builder
                    // prevents Foundation Models from emitting a second
                    // system-prompt fragment for the same capability.
                    if toolPlan.contains(.readFile) {
                        ReadFileTool(workspaceRoot: workspaceRoot)
                    }
                    if toolPlan.contains(.git) {
                        GitTool(
                            workspaceRoot: workspaceRoot,
                            policy: gitPolicy,
                            executionPolicy: executionPolicy
                        )
                    }
                    if toolPlan.contains(.bash) {
                        BashTool(workspaceRoot: workspaceRoot, executionPolicy: executionPolicy)
                    }
                    if toolPlan.contains(.swiftPackageInit) {
                        SwiftPackageInitTool(workspaceRoot: workspaceRoot)
                    }
                    if usesCacheStableToolDefinitions {
                        if toolPlan.contains(.fileSystem) {
                            FileSystemTool(workspaceRoot: workspaceRoot)
                        }
                        if toolPlan.contains(.searchWorkspace) {
                            GrepTool(workspaceRoot: workspaceRoot)
                        }
                    } else if StandaloneSkills.isEnabled(for: toolPlan) {
                        StandaloneSkills(
                            activations: activations,
                            workspaceRoot: workspaceRoot,
                            toolPlan: toolPlan
                        )
                    }
                    if toolPlan.contains(.editFile) {
                        EditFileTool(workspaceRoot: workspaceRoot)
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

// MARK: - Skills

/// Skills-only component for standalone mode.
struct StandaloneSkills: DynamicInstructions {
    let activations: SkillActivations
    let workspaceRoot: String
    let toolPlan: ModelToolPlan

    static func isEnabled(for toolPlan: ModelToolPlan) -> Bool {
        toolPlan.contains(.fileSystem) || toolPlan.contains(.searchWorkspace)
    }

    var body: some DynamicInstructions {
        Skills(activations: activations, skills: configuredSkills)
    }

    private var configuredSkills: [Skill] {
        var skills: [Skill] = []
        if toolPlan.contains(.fileSystem) {
            skills.append(
                Skill(
                    name: "file-browser",
                    description: "Get file metadata, find files by name, and perform file operations in the workspace",
                    allowsDeactivation: true
                ) {
                    Instructions {
                        "Use list_workspace for every directory listing. Use this skill when you need file metadata, file discovery, or file write/delete/copy/move operations."
                    }
                    FileSystemTool(workspaceRoot: workspaceRoot)
                }
            )
        }

        if toolPlan.contains(.searchWorkspace) {
            skills.append(
                Skill(
                    name: "code-reader",
                    description: "Search for text patterns in the workspace",
                    allowsDeactivation: true
                ) {
                    Instructions {
                        "Use this skill when you need to search for code patterns with grep. The read_file tool is already active directly."
                    }
                    GrepTool(workspaceRoot: workspaceRoot)
                }
            )
        }
        return skills
    }
}
