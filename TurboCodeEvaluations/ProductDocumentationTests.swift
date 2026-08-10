import Foundation
import Testing
@testable import TurboCode

@Suite("Product documentation")
struct ProductDocumentationTests {
    @Test("The guide indexes a complete tool-call reference")
    func toolCallReferenceIsSearchableAndComplete() throws {
        let documentationDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TurboCode/Documentation", isDirectory: true)
        let store = ProductDocumentationStore(
            officialDirectoryURL: documentationDirectory,
            bundleResourceURL: nil
        )

        let result = try store.search("Quali tool call sono disponibili?")
        #expect(result.documents.first?.descriptor.id == "tools")
        let tools = try #require(
            result.documents.first(where: { $0.descriptor.id == "tools" })
        )

        // Keep the user-facing reference synchronized with every public
        // capability identifier plus Codex's provider-specific edit alias.
        for id in ToolCapabilityID.allCases {
            #expect(tools.content.contains("`\(id.rawValue)`"))
        }
        #expect(tools.content.contains("`apply_edits`"))
    }

    @Test("The local documentation command reuses the guide presentation")
    func localGuideResolutionProducesNativeWidgetData() throws {
        let documentationDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TurboCode/Documentation", isDirectory: true)
        let store = ProductDocumentationStore(
            officialDirectoryURL: documentationDirectory,
            bundleResourceURL: nil
        )

        let resolution = try TurboCodeGuideTool(store: store)
            .resolve(query: "What can TurboCode do?")

        #expect(resolution.presentation.title == "What TurboCode Can Do")
        #expect(resolution.presentation.documentationVersion == "1.5.0")
        #expect(resolution.presentation.sources.contains { $0.id == "capabilities" })
        #expect(resolution.markdown.contains("TurboCode"))
        #expect(resolution.documentContext.contains("<document id=\"capabilities\""))
    }
}
