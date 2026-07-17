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
    let executionPolicy: ExecutionPolicy
    let gitPolicy: GitPolicy
    let toolPlan: ModelToolPlan
    let usesExclusiveToolSelection: Bool
    let supplementalTools: [any Tool]
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
            if usesExclusiveToolSelection {
                // Dynamic profiles are capability boundaries. Register the
                // resolved instances directly so FoundationModelsUtilities
                // cannot add activation tools or other implicit capabilities.
                supplementalTools
            } else {
                if !workspaceRoot.isEmpty {
                    if toolPlan.contains(.swiftWorkspaceMap) {
                        Instructions {
                            "For broad work in an existing Swift project, call swift_workspace_map before reading files. Use its declaration line numbers to keep read_file calls focused."
                        }
                    }
                    if toolPlan.contains(.readFile) {
                        Instructions {
                            "Use read_file with small line ranges and its Revision for focused context."
                        }
                        ReadFileTool(workspaceRoot: workspaceRoot)
                    }
                    if toolPlan.contains(.git) {
                        Instructions {
                            "Use git for every Git operation, including init when the workspace is not yet a repository; Git writes are not blocked by the bash sandbox."
                        }
                        GitTool(
                            workspaceRoot: workspaceRoot,
                            policy: gitPolicy,
                            executionPolicy: executionPolicy
                        )
                    }
                    if toolPlan.contains(.bash) {
                        Instructions {
                            "Use bash only for Swift Package commands, non-Xcode builds and tests, and precise read-only inspection not covered by a structured tool."
                        }
                        BashTool(workspaceRoot: workspaceRoot, executionPolicy: executionPolicy)
                    }
                    if toolPlan.contains(.swiftPackageInit) {
                        Instructions {
                            "Use swift_package_init instead of bash to create a new Swift Package Manager scaffold. Then use edit_file for implementation changes and bash to build or test it."
                        }
                        SwiftPackageInitTool(workspaceRoot: workspaceRoot)
                    }
                    if toolPlan.contains(.xcodeProject) {
                        Instructions {
                            "Use xcode_project instead of bash to inspect, build, or test an Xcode project. Start with inspect when the container or scheme is unknown, and act on the first reported source error before rebuilding."
                        }
                    }
                    if StandaloneSkills.isEnabled(for: toolPlan) {
                        StandaloneSkills(
                            activations: activations,
                            workspaceRoot: workspaceRoot,
                            toolPlan: toolPlan
                        )
                    }
                    if toolPlan.contains(.editFile) {
                        Instructions {
                            "Use edit_file for every text-file creation or modification, one contiguous change per call. TurboCode generates and validates changes internally. Provide line operations against a fresh revision and never write unified diff syntax yourself. When writing long prose, include real newline characters and separate paragraphs with a blank line."
                        }
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
