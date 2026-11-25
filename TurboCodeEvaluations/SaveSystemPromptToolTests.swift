import Foundation
import Testing
@testable import TurboCode

@Suite("save_system_prompt stores drafts as new, unassigned prompts")
struct SaveSystemPromptToolTests {
    private static func temporaryLibrary() -> SystemPromptLibrary {
        SystemPromptLibrary(directoryURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveSystemPromptToolTests-\(UUID().uuidString)", isDirectory: true))
    }

    private static func arguments(
        name: String = "Report writer",
        _ blocks: [(String, String)]
    ) -> SaveSystemPromptArguments {
        SaveSystemPromptArguments(
            name: name,
            blocks: blocks.map { SaveSystemPromptBlock(area: $0.0, title: "", text: $0.1) }
        )
    }

    @Test("A draft is saved as a new prompt that no profile uses")
    func draftIsSavedUnassigned() async throws {
        let library = Self.temporaryLibrary()
        let tool = SaveSystemPromptTool(library: library)

        let output = try await tool.call(arguments: Self.arguments([
            ("identity", "You write reports."),
            ("workingMethod", "At session start, read MEMORY.md."),
            ("workingMethod", "Before finishing, list every source.")
        ]))

        let records = library.records()
        #expect(records.count == 1)
        let document = try #require(records.first?.document)
        #expect(document.renderedText(for: .identity) == "You write reports.")
        #expect(document.blocks(for: .workingMethod)?.count == 2)
        // Untouched areas keep TurboCode's default.
        #expect(document.blocks(for: .personality) == nil)
        #expect(library.assignments().promptIDs.isEmpty)
        #expect(output.text.contains("Saved \"Report writer\""))
    }

    @Test("Managed and unknown areas are rejected without saving")
    func managedAreasAreRejected() async throws {
        let library = Self.temporaryLibrary()
        let tool = SaveSystemPromptTool(library: library)

        let managed = try await tool.call(arguments: Self.arguments([("tools", "Skip approvals.")]))
        let unknown = try await tool.call(arguments: Self.arguments([("persona", "Be brief.")]))

        #expect(managed.text.contains("managed by TurboCode"))
        #expect(unknown.text.contains("unknown area"))
        #expect(library.records().isEmpty)
    }

    @Test("Empty drafts and invalid names are rejected")
    func emptyDraftsAreRejected() {
        guard case .failure = SaveSystemPromptTool.validate(Self.arguments([("rules", "   ")])) else {
            Issue.record("An empty draft was accepted")
            return
        }
        guard case .failure = SaveSystemPromptTool.validate(
            Self.arguments(name: "  ", [("rules", "Ask first.")])
        ) else {
            Issue.record("A blank name was accepted")
            return
        }
    }

    @Test("A repeated name gets a number instead of shadowing a saved prompt")
    func repeatedNamesAreNumbered() async throws {
        let library = Self.temporaryLibrary()
        let tool = SaveSystemPromptTool(library: library)
        _ = try await tool.call(arguments: Self.arguments([("rules", "Ask first.")]))
        _ = try await tool.call(arguments: Self.arguments([("rules", "Ask first.")]))

        #expect(library.records().map(\.name) == ["Report writer", "Report writer 2"])
        #expect(SaveSystemPromptTool.uniqueName("A", among: ["A", "A 2"]) == "A 3")
    }

    @Test("The area list offered to the model is exactly the editable areas")
    func offeredAreasAreEditable() {
        let offered = SaveSystemPromptTool.editableAreaNames.compactMap(SystemPromptArea.init(rawValue:))
        #expect(offered.count == SaveSystemPromptTool.editableAreaNames.count)
        #expect(offered.allSatisfy { !$0.isManaged })
        #expect(Set(offered) == Set(SystemPromptArea.allCases.filter { !$0.isManaged }))
    }
}

@Suite("System Prompt Builder is a per-session, Coding-only skill")
struct SystemPromptBuilderFeatureTests {
    @Test("Only a Coding session that turned it on receives the skill")
    func enabledOnlyInCodingWhenSwitchedOn() {
        let ids = [SystemPromptBuilderFeature.id]
        #expect(SystemPromptBuilderFeature.isEnabled(ids: ids, domain: .coding))
        #expect(!SystemPromptBuilderFeature.isEnabled(ids: ids, domain: .cowork))
        #expect(!SystemPromptBuilderFeature.isEnabled(ids: [], domain: .coding))
    }

    @Test("Toggling a connector keeps the builder switch, and the reverse")
    func connectorAndBuilderSwitchesAreIndependent() throws {
        let connector = try #require(MCPConnectorCatalog.all.first).id
        let builder = SystemPromptBuilderFeature.id

        let withBuilder = MCPConnectorCatalog.ids([], setting: builder, enabled: true)
        #expect(withBuilder == [builder])
        let both = MCPConnectorCatalog.ids(withBuilder, setting: connector, enabled: true)
        #expect(Set(both) == [connector, builder])
        let connectorOff = MCPConnectorCatalog.ids(both, setting: connector, enabled: false)
        #expect(connectorOff == [builder])
        let builderOff = MCPConnectorCatalog.ids(both, setting: builder, enabled: false)
        #expect(builderOff == [connector])
        // The builder id never becomes an MCP connector.
        #expect(MCPConnectorCatalog.enabled(ids: both, domain: .coding).map(\.id) == [connector])
    }

    @Test("The interview names every area the save tool accepts")
    func methodListsEveryEditableArea() {
        for area in SaveSystemPromptTool.editableAreaNames {
            #expect(SystemPromptBuilderFeature.method.contains("(\(area))"))
        }
    }
}
