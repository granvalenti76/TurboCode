import Foundation
import Testing
@testable import TurboCode

@Suite("Editorial desk")
struct EditorialDeskTests {
    @Test("default editorial catalog is neutral and empty")
    func defaultEditorialCatalogIsEmpty() {
        #expect(EditorialDeskCatalog.default.sections.isEmpty)
        #expect(EditorialDeskCatalog.default.types.isEmpty)
    }

    @Test("editorial catalog round-trips its configurable metadata")
    func editorialCatalogRoundTrips() throws {
        let catalog = EditorialDeskCatalog(
            sections: [
                EditorialDeskSection(
                    name: "Culture",
                    systemImage: "books.vertical"
                )
            ],
            types: [
                EditorialDeskType(
                    name: "Analysis",
                    systemImage: "chart.bar.xaxis",
                    colorHex: "#34C759"
                )
            ]
        )

        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(EditorialDeskCatalog.self, from: data)

        #expect(decoded == catalog)
    }

    @Test("A new desk is empty and direct writing builds the document")
    @MainActor
    func newDeskStartsEmptyAndSupportsDirectWriting() {
        let viewModel = EditorialDeskViewModel(workspaceRoot: "/tmp/workspace")

        #expect(viewModel.draftText.isEmpty)
        #expect(viewModel.sources.isEmpty)
        #expect(!viewModel.hasDocument)

        viewModel.updateTitle("A new headline")
        viewModel.updateDeck("A short deck")
        viewModel.updateBody("The article starts here.")

        #expect(viewModel.draftText == "A new headline\n\nA short deck\n\nThe article starts here.")
        #expect(viewModel.hasDocument)
    }

    @Test("prompt keeps request, document, and ground truth distinct")
    func promptSeparatesEditorialInputs() {
        let request = EditorialRequest(
            userInstruction: "Check the lead",
            document: "Draft claim",
            sources: [
                EditorialSource(
                    name: "Programme brief",
                    origin: .pasted,
                    content: "Authoritative claim"
                )
            ],
            action: .verifyFacts
        )

        let prompt = EditorialPromptBuilder.makePrompt(for: request)

        #expect(prompt.contains("<user_request>\nCheck the lead"))
        #expect(prompt.contains("<editorial_document>\nDraft claim"))
        #expect(prompt.contains("name=\"Programme brief\""))
        #expect(prompt.contains("Authoritative claim"))
        #expect(prompt.contains("Treat every ground-truth source below as authoritative"))
    }

    @Test("canonical publish prompt carries the transcript and selected ground truth")
    func canonicalPublishPromptCarriesEditorialContext() {
        let prompt = EditorialPromptBuilder.makeCanonicalPublishPrompt(
            document: "Published article",
            fileName: "Politics.md",
            sources: [
                EditorialSource(
                    name: "Programme brief",
                    origin: .notes,
                    content: "Authoritative programme claim"
                )
            ]
        )

        #expect(prompt.contains("Politics.md"))
        #expect(prompt.contains("<published_editorial_document"))
        #expect(prompt.contains("Published article"))
        #expect(prompt.contains("Authoritative programme claim"))
        #expect(prompt.contains("Treat the published document as the canonical editorial transcript"))
    }

    @Test("canonical publish prompt carries selected editorial metadata")
    func canonicalPublishPromptCarriesEditorialMetadata() {
        let metadata = EditorialDeskMetadata(
            section: EditorialDeskSection(
                name: "Politics",
                systemImage: "building.columns"
            ),
            type: EditorialDeskType(
                name: "Breaking",
                systemImage: "bolt.fill",
                colorHex: "#FF3B30"
            )
        )

        let prompt = EditorialPromptBuilder.makeCanonicalPublishPrompt(
            document: "Published article",
            fileName: "Politics.md",
            sources: [],
            metadata: metadata
        )

        #expect(prompt.contains("<editorial_metadata>"))
        #expect(prompt.contains("section=\"Politics\""))
        #expect(prompt.contains("type=\"Breaking\""))
        #expect(prompt.contains("color=\"#FF3B30\""))
    }

    @Test("structured model response decodes from a JSON fence")
    func decodesStructuredResponse() throws {
        let response = """
        ```json
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "revisedDocument": "Revised draft",
          "findings": [],
          "summary": "Reviewed against sources"
        }
        ```
        """

        let result = try EditorialResult.decode(from: response)

        #expect(result.revisedDocument == "Revised draft")
        #expect(result.findings.isEmpty)
        #expect(result.summary == "Reviewed against sources")
    }

    @Test("source loader preserves arbitrary selected file provenance")
    func loadsArbitrarySource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialDeskTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("release-notes.custom")
        try Data("Ground truth".utf8).write(to: file)

        let source = try EditorialSourceLoader.load(
            from: file,
            workspaceRoot: root.path
        )

        #expect(source.name == "release-notes")
        #expect(source.content == "Ground truth")
        #expect(source.origin == .importedFile(path: "release-notes.custom"))
    }

    @Test("applying a revision remains undoable")
    @MainActor
    func revisionCanBeUndone() {
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        viewModel.loadDraft("Original draft")
        viewModel.result = EditorialResult(
            revisedDocument: "Revised draft",
            findings: [],
            summary: "Updated"
        )

        viewModel.applyRevision()
        #expect(viewModel.draftText == "Revised draft")
        #expect(viewModel.canUndoDraft)

        viewModel.undoDraft()
        #expect(viewModel.draftText == "Original draft")
        #expect(viewModel.canRedoDraft)
    }

    @Test("intake tabs preserve source provenance")
    @MainActor
    func intakeTabCreatesTranscriptSource() {
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        viewModel.selectedTab = .transcript
        viewModel.intakeName = "Interview transcript"
        viewModel.intakeText = "Speaker statement"

        viewModel.addIntakeAsSource()

        #expect(viewModel.sources.count == 1)
        #expect(viewModel.sources[0].name == "Interview transcript")
        #expect(viewModel.sources[0].origin == .transcript)
        #expect(viewModel.selectedSourceIDs.contains(viewModel.sources[0].id))
    }

    @Test("ground truth source selection is reversible")
    @MainActor
    func sourceSelectionAndRemovalAreReversible() {
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        let source = EditorialSource(
            name: "Product brief",
            origin: .notes,
            content: "Authoritative material"
        )
        viewModel.sources = [source]
        viewModel.selectedSourceIDs = [source.id]

        viewModel.toggleSource(source.id)
        #expect(viewModel.selectedSources.isEmpty)

        viewModel.renameSource(source.id, to: "Renamed brief")
        #expect(viewModel.sources[0].name == "Renamed brief")

        viewModel.removeSource(source.id)
        #expect(viewModel.sources.isEmpty)
        #expect(viewModel.selectedSourceIDs.isEmpty)
    }

    @Test("publish uses the title and never overwrites a previous draft")
    func publisherUsesTitleAndAvoidsCollisions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialPublicationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try EditorialDraftPublisher.publish(
            document: "First draft",
            title: "Politics / Lead",
            workspaceRoot: root.path
        )
        let second = try EditorialDraftPublisher.publish(
            document: "Second draft",
            title: "Politics / Lead",
            workspaceRoot: root.path
        )

        #expect(first.fileName == "Politics---Lead.md")
        #expect(second.fileName == "Politics---Lead-2.md")
        #expect(String(data: try Data(contentsOf: first.url), encoding: .utf8) == "First draft")
        #expect(String(data: try Data(contentsOf: second.url), encoding: .utf8) == "Second draft")
    }

    @Test("publish serializes editorial metadata as Markdown front matter")
    func publisherSerializesEditorialMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialMetadataPublicationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let metadata = EditorialDeskMetadata(
            section: EditorialDeskSection(
                name: "Politics",
                systemImage: "building.columns"
            ),
            type: EditorialDeskType(
                name: "Breaking",
                systemImage: "bolt.fill",
                colorHex: "#FF3B30"
            )
        )
        let publication = try EditorialDraftPublisher.publish(
            document: "Published article",
            title: "Politics",
            workspaceRoot: root.path,
            metadata: metadata
        )

        let contents = try String(contentsOf: publication.url, encoding: .utf8)
        #expect(contents.hasPrefix("---\n"))
        #expect(contents.contains("editorial_section: \"Politics\""))
        #expect(contents.contains("editorial_section_symbol: \"building.columns\""))
        #expect(contents.contains("editorial_type: \"Breaking\""))
        #expect(contents.contains("editorial_type_symbol: \"bolt.fill\""))
        #expect(contents.contains("editorial_type_color: \"#FF3B30\""))
        #expect(contents.hasSuffix("---\n\nPublished article"))
    }

    @Test("publish creates a temporary name when the title is empty")
    func publisherFallsBackToTemporaryName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialTemporaryPublicationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let publication = try EditorialDraftPublisher.publish(
            document: "Untitled draft",
            title: "   ",
            workspaceRoot: root.path,
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(publication.fileName.hasPrefix("Untitled-Draft-1970-01-01-"))
        #expect(publication.fileName.hasSuffix(".md"))
        #expect(FileManager.default.fileExists(atPath: publication.url.path))
    }
}
