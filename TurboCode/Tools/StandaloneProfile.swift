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
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)?
    let onToolEnd: (@Sendable (Transcript.ToolCall) async -> Void)?

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
            if !workspaceRoot.isEmpty {
                Instructions {
                    "read_file and bash are active directly in this session. Use read_file with small line ranges for focused context. Use bash for Git queries, builds, tests, and precise workspace inspection; every Bash command requires approval unless Auto-run is selected. For existing source and text files, use diff_patch structured edits with exact oldText/newText copied from a fresh read_file result."
                }
                ReadFileTool(workspaceRoot: workspaceRoot)
                BashTool(workspaceRoot: workspaceRoot)
                StandaloneSkills(
                    activations: activations,
                    workspaceRoot: workspaceRoot,
                    diskSkills: diskSkills
                )
                Instructions {
                    "diff_patch is active directly in this session. Prefer structured edits for existing files and raw unified patches for new files; do not claim that an editing skill must be activated first."
                }
                DiffPatchTool(workspaceRoot: workspaceRoot)
            } else if !diskSkills.isEmpty {
                DiskSkills(activations: activations, skills: diskSkills)
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
    let diskSkills: [TurboCodeSkillDefinition]

    private var eligibleDiskSkills: [TurboCodeSkillDefinition] {
        diskSkills.filter { $0.name != "file-browser" && $0.name != "code-reader" }
    }

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

            for skill in eligibleDiskSkills {
                Skill(
                    name: skill.name,
                    description: skill.description,
                    prompt: skill.prompt
                )
            }
        }
    }
}

struct DiskSkills: DynamicInstructions {
    let activations: SkillActivations
    let skills: [TurboCodeSkillDefinition]

    var body: some DynamicInstructions {
        Skills(
            activations: activations,
            strictSchema: true,
            skills: skills.map {
                Skill(name: $0.name, description: $0.description, prompt: $0.prompt)
            }
        )
    }
}
