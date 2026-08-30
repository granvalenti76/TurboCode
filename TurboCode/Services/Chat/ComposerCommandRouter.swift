import Foundation
import Observation

@MainActor
struct ComposerCommandActions {
    let openDocumentation: () async -> Void
    let compact: () async -> Void
    let reload: () async -> Void
    let runTask: (String) async -> Void
    let reportError: (String) -> Void
}

/// Dispatches composer-owned commands to narrow application actions.
///
/// The router deliberately does not know about conversation storage, provider
/// sessions, or model tools. This keeps `/reload` and future plugin commands
/// outside `ChatStore`'s prompt and transcript responsibilities.
@MainActor
@Observable
final class ComposerCommandRouter {
    private let actions: ComposerCommandActions

    init(actions: ComposerCommandActions) {
        self.actions = actions
    }

    func isLocalCommand(_ text: String) -> Bool {
        ComposerCommandParser.parse(text) != nil
    }

    func isIncompleteSkillCommand(_ text: String) -> Bool {
        ComposerCommandParser.isIncompleteSkillCommand(text)
    }

    func isIncompleteTaskCommand(_ text: String) -> Bool {
        ComposerCommandParser.isIncompleteTaskCommand(text)
    }

    @discardableResult
    func execute(_ text: String) async -> Bool {
        guard let command = ComposerCommandParser.parse(text) else { return false }

        switch command {
        case .documentation:
            await actions.openDocumentation()
        case .compact:
            await actions.compact()
        case .reload:
            await actions.reload()
        case .task(let goal):
            guard let goal else {
                actions.reportError("Use /task followed by the task instructions.")
                return true
            }
            await actions.runTask(goal)
        }
        return true
    }
}
