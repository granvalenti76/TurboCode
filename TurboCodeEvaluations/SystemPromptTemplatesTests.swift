import Foundation
import Testing
@testable import TurboCode

@Suite("System prompt templates, import, and library model")
@MainActor
struct SystemPromptTemplatesTests {
    private static func temporaryLibrary() -> SystemPromptLibrary {
        SystemPromptLibrary(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemPromptTemplatesTests-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("A duplicate of the default reads like the default plus the precedence line")
    func duplicateMatchesDefault() {
        let tuning = AgentTuningConfig.default
        let copy = SystemPromptTemplates.duplicateOfDefault(tuning: tuning)
        let builtIn = TurboCodeSystemPromptBuilder.build(SystemPromptTemplates.codingContext(tuning: tuning))
        let duplicated = TurboCodeSystemPromptBuilder.build(SystemPromptTemplates.codingContext(tuning: tuning, document: copy))

        #expect(copy.isCustomized)
        // Areas with no built-in text are not copied as empty overrides.
        #expect(copy.blocks(for: .rules) == nil)
        #expect(duplicated.contains("Precedence:"))
        #expect(duplicated.replacingOccurrences(of: Self.precedenceParagraph(in: duplicated), with: "") == builtIn)
    }

    private static func precedenceParagraph(in prompt: String) -> String {
        guard let start = prompt.range(of: "\n\nPrecedence:"),
              let end = prompt.range(of: "\n\nAbout TurboCode:", range: start.upperBound..<prompt.endIndex)
        else { return "" }
        return String(prompt[start.lowerBound..<end.lowerBound])
    }

    @Test("A blank prompt keeps only an Identity block among the default areas")
    func blankPromptStartsEmpty() {
        let blank = SystemPromptTemplates.blank()
        let prompt = TurboCodeSystemPromptBuilder.build(SystemPromptTemplates.codingContext(tuning: .default, document: blank))
        #expect(blank.renderedText(for: .identity)?.isEmpty == false)
        #expect(!prompt.contains("Working principles:"))
        #expect(!prompt.contains(TurboCodePersonality.default.prompt))
        // Managed areas are still added.
        #expect(prompt.contains("About TurboCode:"))
    }

    @Test("Markdown import maps ## headings to areas and keeps other areas at their default")
    func markdownImportMapsHeadings() {
        let markdown = """
            You are Ada, a Swift pair programmer.

            ## Personality
            Warm and direct.

            ## rules
            Never use tables.

            ## My stack
            SwiftUI on macOS.

            ## Rules
            Ask before deleting.
            """
        let document = SystemPromptTemplates.importMarkdown(markdown)
        #expect(document.renderedText(for: .identity) == "You are Ada, a Swift pair programmer.")
        #expect(document.renderedText(for: .personality) == "Warm and direct.")
        #expect(document.renderedText(for: .rules) == "Never use tables.\n\nAsk before deleting.")
        #expect(document.blocks(for: .userContext)?.map(\.title) == ["My stack"])
        #expect(document.blocks(for: .workingMethod) == nil)
    }

    @Test("Every section of the prompt is tagged with an area in the fixed order")
    func sectionsFollowAreaOrder() {
        let context = SystemPromptTemplates.editorContext(tuning: .default, document: .turboCodeDefault)
        let areas = TurboCodeSystemPromptBuilder.sections(context).map(\.area)
        let order = SystemPromptArea.allCases
        let indices = areas.map { order.firstIndex(of: $0)! }
        #expect(indices == indices.sorted())
        #expect(areas.contains(.tools) && areas.contains(.session))
        #expect(TurboCodeSystemPromptBuilder.sections(context).map(\.text).joined(separator: "\n\n")
            == TurboCodeSystemPromptBuilder.build(context))
    }

    @Test("The library model names copies uniquely and rebuilds only for prompts in use")
    func libraryModelNotifiesOnlyForAssignedPrompts() throws {
        var notifications = 0
        let model = SystemPromptLibraryViewModel(library: Self.temporaryLibrary()) { notifications += 1 }
        model.load()

        let first = try #require(model.create(.duplicateDefault, tuning: .default))
        let second = try #require(model.create(.duplicateDefault, tuning: .default))
        #expect(first.name == "TurboCode default copy")
        #expect(second.name == "TurboCode default copy 2")
        #expect(notifications == 0)

        var edited = first.document
        edited.setBlocks([SystemPromptBlock(title: "Me", text: "You are Ada.")], for: .identity)
        model.updateDocument(first.id, to: edited)
        #expect(model.record(first.id)?.version == 2)
        #expect(notifications == 0)

        model.assign(.coding, to: first.id)
        #expect(notifications == 1)
        #expect(model.profiles(using: first.id) == [.coding])

        model.rename(first.id, to: "Ada")
        #expect(notifications == 1)

        edited.setBlocks([SystemPromptBlock(title: "Me", text: "You are Ada, again.")], for: .identity)
        model.updateDocument(first.id, to: edited)
        #expect(notifications == 2)

        model.delete(first.id)
        #expect(notifications == 3)
        #expect(model.profiles(using: nil).contains(.coding))
    }
}
