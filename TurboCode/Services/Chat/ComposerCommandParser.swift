import Foundation

/// Parses only commands owned by TurboCode's composer. Skill activation remains
/// prompt syntax because the selected model owns its skill-loading behavior.
nonisolated enum ComposerCommandParser {
    static func parse(_ text: String) -> ComposerCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "/documentation":
            return .documentation
        case "/compact":
            return .compact
        case "/reload":
            return .reload
        case "/task":
            return .task(nil)
        default:
            guard trimmed.hasPrefix("/task ") else { return nil }
            let goal = String(trimmed.dropFirst("/task ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return goal.isEmpty ? .task(nil) : .task(goal)
        }
    }

    static func isIncompleteSkillCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "/skill"
    }

    static func isIncompleteTaskCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "/task"
    }
}
