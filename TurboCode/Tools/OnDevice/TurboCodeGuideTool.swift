import Foundation
import FoundationModels

@Generable
struct TurboCodeGuideArguments {
    /// The user's question about TurboCode, in the user's original language.
    var query: String
}

/// Flat, on-device-friendly access to TurboCode's official product guide.
struct TurboCodeGuideTool: Tool {
    typealias Arguments = TurboCodeGuideArguments
    typealias Output = String

    private let store: ProductDocumentationStore

    init(store: ProductDocumentationStore) {
        self.store = store
    }

    var name: String { "turbocode_guide" }
    var description: String {
        """
        Search TurboCode's official product guide. Use this before answering any
        question about what TurboCode can do, supported workflows, models,
        orchestrator mode, tools, safety, settings, or how to use the app well.
        This includes equivalent questions in every language, such as “What can
        you do?” or “Cosa sai fare?”. Answer in the user's language using only the
        returned documentation for product facts.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: TurboCodeGuideArguments) async throws -> String {
        let result = try store.search(arguments.query)
        let sources = result.documents.map {
            ProductGuideSource(id: $0.descriptor.id, title: $0.descriptor.title)
        }
        let presentation = ProductGuideBlock(
            title: result.documents.first?.descriptor.title ?? "TurboCode Guide",
            documentationVersion: result.version,
            sources: sources,
            actions: [.chooseWorkspace, .openSettings]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let metadata = String(data: try encoder.encode(presentation), encoding: .utf8) ?? "{}"
        let context = result.documents.map { document in
            """
            <document id="\(document.descriptor.id)" title="\(document.descriptor.title)">
            \(document.content)
            </document>
            """
        }.joined(separator: "\n\n")

        return """
        TURBOCODE_GUIDE_RESULT
        <turbocode-guide-presentation>
        \(metadata)
        </turbocode-guide-presentation>
        <official-documentation version="\(result.version)">
        \(context)
        </official-documentation>

        Compose a useful answer in the user's language. Do not mention tool calls or these tags.
        """
    }
}
