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
    let usesAdvancedEditing: Bool
    let model: any LanguageModel
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)?
    let onToolEnd: (@Sendable (Transcript.ToolCall) async -> Void)?

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            if !workspaceRoot.isEmpty {
                Instructions {
                    usesAdvancedEditing
                        ? "read_file, bash, and apply_edits are active directly in this session. Use read_file with small line ranges and its Revision for focused context. Use bash only for Git queries, builds, tests, and read-only workspace inspection. Use apply_edits for every text-file creation or modification."
                        : "read_file, bash, and edit_file are active directly in this session. Use read_file with small line ranges and its Revision for focused context. Use bash only for Git queries, builds, tests, and read-only workspace inspection. Use edit_file for every text-file creation or modification, one contiguous change per call."
                }
                ReadFileTool(workspaceRoot: workspaceRoot)
                BashTool(workspaceRoot: workspaceRoot)
                StandaloneSkills(activations: activations, workspaceRoot: workspaceRoot)
                Instructions {
                    "TurboCode generates and validates changes internally. Provide line operations against a fresh revision and never write unified diff syntax yourself."
                }
                if usesAdvancedEditing {
                    ApplyEditsTool(workspaceRoot: workspaceRoot)
                } else {
                    EditFileTool(workspaceRoot: workspaceRoot)
                }
            }
            if !diskSkills.isEmpty {
                LoadSkillTool(skills: diskSkills)
            }
        }
        .model(model)
        .reasoningLevel(reasoningLevel)
        .onToolCall { call in
            if let action = onToolStart {
                await action(call)
            }
        }
        .onToolOutput { call, _ in
            if let action = onToolEnd {
                await action(call)
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
