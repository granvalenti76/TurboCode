import Foundation
import FoundationModels

@Generable
struct CreateSkillArguments {
    /// Lowercase kebab-case skill identifier.
    var name: String
    /// Concise trigger description used for implicit activation.
    var description: String
    /// Complete procedural instructions for the skill body.
    var instructions: String
}

/// Creates a Codex-compatible workspace skill through the same reviewable edit
/// transaction used by every other model-authored file change.
struct CreateSkillTool: Tool {
    typealias Arguments = CreateSkillArguments
    typealias Output = ToolCommandOutput

    let workspaceRoot: String
    private let receiptRegistry: ToolReceiptRegistry?

    init(workspaceRoot: String, receiptRegistry: ToolReceiptRegistry? = nil) {
        self.workspaceRoot = workspaceRoot
        self.receiptRegistry = receiptRegistry
    }

    var name: String { "create_skill" }
    var description: String {
        "Create one reusable Codex-compatible skill at .agents/skills/<name>/SKILL.md in the active workspace."
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: CreateSkillArguments) async throws -> ToolCommandOutput {
        let skillName = arguments.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let skillDescription = arguments.description.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let skillInstructions = arguments.instructions.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard skillName.range(
            of: "^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$",
            options: .regularExpression
        ) != nil else {
            return "Skill creation rejected: name must use lowercase letters, digits, and hyphens (max 64 characters)."
        }
        guard !skillDescription.isEmpty,
              !skillDescription.contains("\n"),
              !skillDescription.contains("---") else {
            return "Skill creation rejected: description must be one concise line without YAML delimiters."
        }
        guard !skillInstructions.isEmpty else {
            return "Skill creation rejected: instructions cannot be empty."
        }

        let content = """
        ---
        name: \(skillName)
        description: \(skillDescription)
        ---
        \(skillInstructions)
        """
        return try await EditFileTool(
            workspaceRoot: workspaceRoot,
            receiptRegistry: receiptRegistry
        ).call(
            arguments: EditFileArguments(
                filePath: ".agents/skills/\(skillName)/SKILL.md",
                revision: nil,
                operation: "create",
                startLine: nil,
                endLine: nil,
                content: content
            )
        )
    }
}
