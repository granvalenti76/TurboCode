import Testing
@testable import TurboCode

@MainActor
@Suite("Composer commands")
struct ComposerCommandTests {
    @Test("Parser recognizes local commands and preserves task goals")
    func parserRecognizesLocalCommands() {
        #expect(ComposerCommandParser.parse(" /reload ") == .reload)
        #expect(ComposerCommandParser.parse("/documentation") == .documentation)
        #expect(ComposerCommandParser.parse("/compact") == .compact)
        #expect(
            ComposerCommandParser.parse("/task inspect the workspace")
                == .task("inspect the workspace")
        )
        #expect(ComposerCommandParser.parse("ordinary prompt") == nil)
    }

    @Test("Parser keeps incomplete composer forms out of execution")
    func parserRecognizesIncompleteForms() {
        #expect(ComposerCommandParser.isIncompleteSkillCommand(" /skill "))
        #expect(ComposerCommandParser.isIncompleteTaskCommand("/task"))
        #expect(ComposerCommandParser.parse("/task") == .task(nil))
        #expect(ComposerCommandParser.parse("/task   ") == .task(nil))
    }

    @Test("Router dispatches reload without sending a model prompt")
    func routerDispatchesReload() async {
        var events: [String] = []
        let router = ComposerCommandRouter(
            actions: ComposerCommandActions(
                openDocumentation: { events.append("documentation") },
                compact: { events.append("compact") },
                reload: { events.append("reload") },
                runTask: { events.append("task:\($0)") },
                reportError: { events.append("error:\($0)") }
            )
        )

        #expect(await router.execute("/reload"))
        #expect(events == ["reload"])
    }

    @Test("Router reports incomplete tasks and rejects ordinary prompts")
    func routerHandlesIncompleteTask() async {
        var events: [String] = []
        let router = ComposerCommandRouter(
            actions: ComposerCommandActions(
                openDocumentation: {},
                compact: {},
                reload: {},
                runTask: { events.append("task:\($0)") },
                reportError: { events.append($0) }
            )
        )

        #expect(await router.execute("/task"))
        #expect(events == ["Use /task followed by the task instructions."])
        #expect(await router.execute("ordinary prompt") == false)
    }
}
