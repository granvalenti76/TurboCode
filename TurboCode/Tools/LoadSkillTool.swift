import Foundation
import FoundationModels

@Generable
struct LoadSkillArguments {
    /// Exact skill name from the available skills catalog.
    var name: String
}

/// Loads a disk-backed skill body on demand without relying on a dynamic enum
/// schema, which keeps malformed model arguments recoverable on beta runtimes.
struct LoadSkillTool: Tool {
    typealias Arguments = LoadSkillArguments
    typealias Output = String

    let skills: [TurboCodeSkillDefinition]

    var name: String { "load_skill" }
    var description: String {
        "Load the full instructions for one reusable TurboCode skill when the user's request matches its catalog description."
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: LoadSkillArguments) async throws -> String {
        let requestedName = arguments.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let skill = skills.first(where: { $0.name == requestedName }) else {
            let available = skills.map(\.name).joined(separator: ", ")
            return "Skill '\(requestedName)' was not found. Available skills: \(available)."
        }

        return """
        Loaded TurboCode skill: \(skill.name)

        <skill name="\(skill.name)">
        \(skill.prompt)
        </skill>

        Follow this skill for the current request.
        """
    }
}
