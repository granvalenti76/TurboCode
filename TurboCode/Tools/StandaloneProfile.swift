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
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let dropsCompletedToolCalls: Bool
    let executionPolicy: ExecutionPolicy
    let gitPolicy: GitPolicy
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
            if !workspaceRoot.isEmpty {
                Instructions {
                    "read_file, git, bash, and edit_file are active directly in this session. Use read_file with small line ranges and its Revision for focused context. Use git for every Git operation, including init when the workspace is not yet a repository; Git writes are not blocked by the bash sandbox. Use bash only for builds, tests, and precise read-only inspection not covered by a structured tool. Use edit_file for every text-file creation or modification, one contiguous change per call. When writing articles, biographies, documentation, or other long prose, include real newline characters and separate paragraphs with a blank line; never collapse the document into one long line."
                }
                ReadFileTool(workspaceRoot: workspaceRoot)
                GitTool(
                    workspaceRoot: workspaceRoot,
                    policy: gitPolicy,
                    executionPolicy: executionPolicy
                )
                BashTool(workspaceRoot: workspaceRoot, executionPolicy: executionPolicy)
                StandaloneSkills(activations: activations, workspaceRoot: workspaceRoot)
                Instructions {
                    "TurboCode generates and validates changes internally. Provide line operations against a fresh revision and never write unified diff syntax yourself."
                }
                EditFileTool(workspaceRoot: workspaceRoot)
            }
            if !diskSkills.isEmpty {
                LoadSkillTool(skills: diskSkills)
            }
            supplementalTools
        }
        .model(model)
        .temperature(temperature)
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

    var body: some DynamicInstructions {
        Skills(activations: activations) {
            Skill(
                name: "file-browser",
                description: "List files, get file metadata, find files by name, and perform file operations in the workspace",
                allowsDeactivation: true
            ) {
                Instructions {
                    "Use this skill when you need to explore the workspace, list directory contents, get file info, find files, or perform file write/delete/copy/move operations."
                }
                FileSystemTool(workspaceRoot: workspaceRoot)
            }

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

        }
    }
}
