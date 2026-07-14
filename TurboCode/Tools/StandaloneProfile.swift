import Foundation
import FoundationModels
import FoundationModelsUtilities

// MARK: - Standalone Profile

/// DynamicProfile for standalone mode with Skills, model selection,
/// and reasoning level control.
struct StandaloneProfile: LanguageModelSession.DynamicProfile {
    let instructions: String
    let activations: SkillActivations
    let workspaceRoot: String
    let model: any LanguageModel
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)?
    let onToolEnd: (@Sendable (Transcript.ToolCall) async -> Void)?

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            if !workspaceRoot.isEmpty {
                StandaloneSkills(activations: activations, workspaceRoot: workspaceRoot)
                Instructions {
                    "diff_patch is active and available directly in this session. Use it for code edits in Git workspaces; do not claim that an editing skill must be activated first."
                }
                DiffPatchTool(workspaceRoot: workspaceRoot)
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
                description: "Read file contents and search for text patterns in the workspace",
                allowsDeactivation: true
            ) {
                Instructions {
                    "Use this skill when you need to read file contents or search for code patterns with grep."
                }
                ReadFileTool(workspaceRoot: workspaceRoot)
                GrepTool(workspaceRoot: workspaceRoot)
            }
        }
    }
}
