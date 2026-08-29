import Foundation
import Testing
@testable import TurboCode

@Suite("Editorial desk")
struct EditorialDeskTests {
    @Test("symbol suggestions are broad and programming-oriented")
    func symbolSuggestionsMatchEditorialContexts() {
        let sectionSymbols = EditorialDeskSymbolCatalog.options(for: .section)
        let typeSymbols = EditorialDeskSymbolCatalog.options(for: .articleType)

        #expect(sectionSymbols.contains { $0.name == "terminal" })
        #expect(sectionSymbols.contains { $0.name == "book.pages" })
        #expect(sectionSymbols.contains { $0.name == "building.columns" })
        #expect(typeSymbols.contains { $0.name == "chevron.left.forwardslash.chevron.right" })
        #expect(typeSymbols.contains { $0.name == "bolt.fill" })
        #expect(typeSymbols.contains { $0.name == "checkmark.seal.fill" })
        #expect(Set(sectionSymbols.map(\.name)).count == sectionSymbols.count)
        #expect(Set(typeSymbols.map(\.name)).count == typeSymbols.count)
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
        #expect(prompt.contains("do not rewrite the editorial document"))
        #expect(prompt.contains("Do not include revisedDraft"))
    }

    @Test("structured model response decodes from a JSON fence")
    func decodesStructuredResponse() throws {
        let response = """
        ```json
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "revisedDraft": {
            "title": "Revised title",
            "deck": "Revised deck",
            "body": "Revised body"
          },
          "findings": [],
          "summary": "Reviewed against sources"
        }
        ```
        """

        let result = try EditorialResult.decode(from: response)

        #expect(result.revisedDraft?.title == "Revised title")
        #expect(result.revisedDraft?.deck == "Revised deck")
        #expect(result.revisedDraft?.body == "Revised body")
        #expect(result.revisedDocument == nil)
        #expect(result.findings.isEmpty)
        #expect(result.summary == "Reviewed against sources")
    }

    @Test("invalid model response stays an explicit decoder error")
    func rejectsInvalidResponse() {
        #expect(throws: DecodingError.self) {
            try EditorialResult.decode(from: "not valid JSON")
        }
    }

    @Test("legacy model response remains decodable")
    func decodesLegacyResponse() throws {
        let response = """
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "revisedDocument": "Legacy revision",
          "findings": [],
          "summary": "Reviewed"
        }
        """

        let result = try EditorialResult.decode(from: response)

        #expect(result.revisedDraft == nil)
        #expect(result.revisedDocument == "Legacy revision")
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

        let outsideRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialOutsideSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        let outsideFile = outsideRoot.appendingPathComponent("outside.txt")
        try Data("External ground truth".utf8).write(to: outsideFile)

        let outsideSource = try EditorialSourceLoader.load(
            from: outsideFile,
            workspaceRoot: root.path
        )
        #expect(outsideSource.origin == .importedFile(path: outsideFile.path))
    }

    @Test("source service keeps successful imports when one file fails")
    func sourceServicePreservesPartialImportResults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialSourceServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let validFile = root.appendingPathComponent("brief.txt")
        let invalidFile = root.appendingPathComponent("binary.dat")
        try Data("Ground truth".utf8).write(to: validFile)
        try Data([0xFF, 0xFE]).write(to: invalidFile)

        let result = await EditorialSourceService().load(
            urls: [validFile, invalidFile],
            workspaceRoot: root.path
        )

        #expect(result.sources.count == 1)
        #expect(result.sources.first?.content == "Ground truth")
        #expect(result.errors.count == 1)
        #expect(result.errors[0].contains("binary.dat"))
    }

    @Test("manual Notes is the only intake tab besides Write")
    func manualSourceTabsAreHonest() {
        #expect(EditorialDeskTab.allCases == [.write, .notes])
        #expect(EditorialDeskTab.notes.rawValue == "Notes (manual)")
    }

    @Test("source service skips duplicate files and preserves provenance")
    func sourceServiceSkipsDuplicateFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialDuplicateSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("brief.txt")
        try Data("Ground truth".utf8).write(to: file)

        let result = await EditorialSourceService().load(
            urls: [file, file],
            workspaceRoot: root.path
        )

        #expect(result.sources.count == 1)
        #expect(result.sources[0].origin == .importedFile(path: "brief.txt"))
        #expect(result.errors.count == 1)
        #expect(result.errors[0].contains("already present"))

        let existing = EditorialSource(
            name: "Existing brief",
            origin: .importedFile(path: "brief.txt"),
            content: "Ground truth"
        )
        let excludedResult = await EditorialSourceService().load(
            urls: [file],
            workspaceRoot: root.path,
            excluding: [existing]
        )
        #expect(excludedResult.sources.isEmpty)
        #expect(excludedResult.errors.count == 1)
    }

    @Test("source service rejects files over the prompt size limit")
    func sourceServiceRejectsOversizedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialLargeSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("large.txt")
        try Data(repeating: 0x61, count: EditorialSourceLoader.maxByteCount + 1).write(to: file)

        let result = await EditorialSourceService().load(
            urls: [file],
            workspaceRoot: root.path
        )

        #expect(result.sources.isEmpty)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].contains("source limit"))
    }

    @Test("manual sources reject duplicate content without losing the first source")
    @MainActor
    func manualSourcesRejectDuplicates() {
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        viewModel.selectedTab = .notes
        viewModel.intakeText = "Same note"
        viewModel.addIntakeAsSource()
        viewModel.addIntakeAsSource()

        #expect(viewModel.sources.count == 1)
        #expect(viewModel.importError?.contains("already present") == true)
    }

    @Test("source preview and byte metadata are derived from frozen content")
    func sourcePresentationMetadataIsStable() {
        let source = EditorialSource(
            name: "Brief",
            origin: .pasted,
            content: "First line\nSecond line"
        )

        #expect(source.byteCount == source.content.lengthOfBytes(using: .utf8))
        #expect(source.preview == "First line Second line")
        #expect(source.provenanceKey == "pasted:\(source.content)")
    }

    @Test("structured revisions preserve every draft field and remain undoable")
    @MainActor
    func structuredRevisionPreservesDraftFields() {
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        viewModel.loadDraft(
            EditorialDraft(
                title: "Original title",
                deck: "Original deck",
                body: "Original body"
            )
        )
        viewModel.result = EditorialResult(
            revisedDraft: EditorialDraft(
                title: "Revised title",
                deck: "Revised deck",
                body: "Revised body"
            ),
            findings: [],
            summary: "Updated"
        )

        viewModel.applyRevision()
        #expect(viewModel.documentTitle == "Revised title")
        #expect(viewModel.documentDeck == "Revised deck")
        #expect(viewModel.documentContent == "Revised body")

        viewModel.undoDraft()
        #expect(viewModel.documentTitle == "Original title")
        #expect(viewModel.documentDeck == "Original deck")
        #expect(viewModel.documentContent == "Original body")
        viewModel.redoDraft()
        #expect(viewModel.documentTitle == "Revised title")
        #expect(viewModel.documentDeck == "Revised deck")
        #expect(viewModel.documentContent == "Revised body")
    }

    @Test("revision diff contains only changed semantic fields")
    func revisionDiffIsFieldScoped() {
        let base = EditorialDraftSnapshot(
            title: "Original title",
            deck: "Original deck",
            body: "Original body",
            revision: 7
        )
        let revision = EditorialRevision(
            base: base,
            proposed: EditorialDraft(
                title: "Revised title",
                deck: "Original deck",
                body: "Revised body"
            )
        )

        #expect(revision.changes.map(\.field) == [.title, .body])
        #expect(revision.changes[0].before == "Original title")
        #expect(revision.changes[0].after == "Revised title")
        #expect(revision.changes[1].before == "Original body")
        #expect(revision.changes[1].after == "Revised body")

        let emptyRevision = EditorialRevision(base: base, proposed: base.draft)
        #expect(emptyRevision.isEmpty)
    }

    @Test("individual review decisions preserve rejected fields and keep undo")
    @MainActor
    func individualReviewDecisionsAreReversible() {
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        viewModel.loadDraft(
            EditorialDraft(title: "Title", deck: "Deck", body: "Body")
        )
        viewModel.result = EditorialResult(
            revisedDraft: EditorialDraft(
                title: "New title",
                deck: "New deck",
                body: "New body"
            ),
            findings: [],
            summary: "Updated"
        )

        viewModel.rejectRevision(for: .title)
        viewModel.applyRevision(for: .deck)
        viewModel.applyAllRevision()

        #expect(viewModel.documentTitle == "Title")
        #expect(viewModel.documentDeck == "New deck")
        #expect(viewModel.documentContent == "New body")
        #expect(viewModel.revisionStatus(for: .title) == .rejected)
        #expect(viewModel.revisionStatus == .partial)
        #expect(viewModel.canUndoDraft)

        viewModel.undoDraft()
        #expect(viewModel.documentContent == "Body")
        viewModel.undoDraft()
        #expect(viewModel.documentDeck == "Deck")
    }

    @Test("rejecting a proposal leaves the current draft untouched")
    @MainActor
    func rejectingProposalDoesNotMutateDraft() {
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        viewModel.loadDraft(EditorialDraft(title: "Title", deck: "Deck", body: "Body"))
        viewModel.result = EditorialResult(
            revisedDraft: EditorialDraft(title: "New title", deck: "Deck", body: "Body"),
            findings: [],
            summary: "Updated"
        )

        viewModel.rejectRevision()

        #expect(viewModel.draftText == "Title\n\nDeck\n\nBody")
        #expect(viewModel.revisionStatus == .rejected)
        #expect(!viewModel.canApplyRevision)
        #expect(!viewModel.canUndoDraft)
    }

    @Test("all findings remain reviewable with independent local status")
    @MainActor
    func allFindingsRemainReviewable() {
        let findings = (0..<6).map { index in
            EditorialFinding(
                id: UUID(),
                sourceName: "Source \(index)",
                documentExcerpt: "Draft \(index)",
                sourceExcerpt: "Evidence \(index)",
                explanation: "Finding \(index)",
                severity: index.isMultiple(of: 2) ? .warning : .note
            )
        }
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        viewModel.result = EditorialResult(
            revisedDraft: nil,
            findings: findings,
            summary: "Six findings"
        )

        #expect(findings.allSatisfy { viewModel.findingStatus(for: $0.id) == .open })
        viewModel.acknowledgeFinding(findings[0].id)
        viewModel.dismissFinding(findings[1].id)

        #expect(viewModel.findingStatus(for: findings[0].id) == .acknowledged)
        #expect(viewModel.findingStatus(for: findings[1].id) == .dismissed)
        #expect(viewModel.findingStatus(for: findings[5].id) == .open)
    }

    @Test("diagnostic actions never admit a draft revision")
    @MainActor
    func diagnosticActionsCannotRewriteDraft() async {
        let viewModel = EditorialDeskViewModel(
            workspaceRoot: "",
            modelClient: DiagnosticEditorialDeskModelClient()
        )
        let snapshot = EditorialDraftSnapshot(
            title: "Original title",
            deck: "Original deck",
            body: "Original body",
            revision: 1
        )

        viewModel.run(action: .verifyFacts, snapshot: snapshot)
        for _ in 0..<20 where viewModel.operationPhase == .running {
            await Task.yield()
        }

        #expect(viewModel.operationPhase == .completed)
        #expect(viewModel.revision == nil)
        #expect(viewModel.draftText == "")
        #expect(viewModel.result?.revisedDraft != nil)
    }

    @Test("manual field edits coalesce and undo as complete draft snapshots")
    @MainActor
    func manualEditsUseCompleteDraftSnapshots() {
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        viewModel.loadDraft(
            EditorialDraft(title: "Title", deck: "Deck", body: "Body")
        )

        viewModel.updateTitle("Title 1")
        viewModel.updateTitle("Title 12")
        viewModel.updateBody("Body 1")

        viewModel.undoDraft()
        #expect(viewModel.draftText == "Title 12\n\nDeck\n\nBody")
        viewModel.undoDraft()
        #expect(viewModel.draftText == "Title\n\nDeck\n\nBody")
        #expect(!viewModel.canUndoDraft)

        viewModel.redoDraft()
        #expect(viewModel.draftText == "Title 12\n\nDeck\n\nBody")
    }

    @Test("many paragraphs stay in the body instead of becoming semantic fields")
    @MainActor
    func manyParagraphsRemainBodyContent() {
        let document = "First paragraph\n\nSecond paragraph\n\nThird paragraph\n\nFourth paragraph"
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        viewModel.loadDraft(document)

        #expect(viewModel.documentTitle.isEmpty)
        #expect(viewModel.documentDeck.isEmpty)
        #expect(viewModel.documentContent == document)
        #expect(viewModel.draftText == document)
    }

    @Test("applying a legacy revision remains undoable")
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

    @Test("manual Notes can become either the article or ground truth")
    @MainActor
    func manualNotesCanCreateDocumentOrSource() {
        let documentViewModel = EditorialDeskViewModel(workspaceRoot: "")
        documentViewModel.selectedTab = .notes
        documentViewModel.intakeText = "Article copy"
        documentViewModel.useIntakeAsDocument()

        #expect(documentViewModel.draftText == "Article copy")
        #expect(documentViewModel.selectedTab == .write)

        let sourceViewModel = EditorialDeskViewModel(workspaceRoot: "")
        sourceViewModel.selectedTab = .notes
        sourceViewModel.intakeName = "Editorial brief"
        sourceViewModel.intakeText = "Authoritative material"
        sourceViewModel.addIntakeAsSource()

        #expect(sourceViewModel.sources.count == 1)
        #expect(sourceViewModel.sources[0].name == "Editorial brief")
        #expect(sourceViewModel.sources[0].origin == .notes)
        #expect(sourceViewModel.sources[0].origin.label == "Notes (manual)")
        #expect(sourceViewModel.selectedSourceIDs.contains(sourceViewModel.sources[0].id))
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
            draft: EditorialDraftSnapshot(
                title: "Politics / Lead",
                body: "First draft",
                revision: 1
            ),
            draftID: UUID(),
            targetRelativePath: nil,
            workspaceRoot: root.path
        )
        let second = try EditorialDraftPublisher.publish(
            draft: EditorialDraftSnapshot(
                title: "Politics / Lead",
                body: "Second draft",
                revision: 1
            ),
            draftID: UUID(),
            targetRelativePath: nil,
            workspaceRoot: root.path
        )

        #expect(first.fileName == "Politics---Lead.md")
        #expect(second.fileName == "Politics---Lead-2.md")
        let firstContents = try String(contentsOf: first.url, encoding: .utf8)
        let secondContents = try String(contentsOf: second.url, encoding: .utf8)
        #expect(EditorialMarkdownCodec.decode(firstContents).draft.body == "First draft")
        #expect(EditorialMarkdownCodec.decode(secondContents).draft.body == "Second draft")
    }

    @Test("publish serializes editorial metadata as Markdown front matter")
    func publisherSerializesEditorialMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialMetadataPublicationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let metadata = EditorialDeskMetadata(
            section: EditorialDeskSection(
                name: "Politics",
                systemImage: "building.columns"
            ),
            type: EditorialDeskType(
                name: "Breaking",
                systemImage: "bolt.fill",
                colorHex: "#FF3B30"
            ),
            date: calendar.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 12))
        )
        let publication = try EditorialDraftPublisher.publish(
            draft: EditorialDraftSnapshot(
                title: "Politics",
                deck: "Daily update",
                body: "Published article",
                revision: 1
            ),
            draftID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            targetRelativePath: nil,
            workspaceRoot: root.path,
            metadata: metadata
        )

        let contents = try String(contentsOf: publication.url, encoding: .utf8)
        #expect(contents.hasPrefix("---\n"))
        #expect(contents.contains("editorial_draft: true"))
        #expect(contents.contains("editorial_draft_id: \"00000000-0000-0000-0000-000000000001\""))
        #expect(contents.contains("title: \"Politics\""))
        #expect(contents.contains("subtitle: \"Daily update\""))
        #expect(contents.contains("editorial_section: \"Politics\""))
        #expect(contents.contains("editorial_section_symbol: \"building.columns\""))
        #expect(contents.contains("editorial_type: \"Breaking\""))
        #expect(contents.contains("editorial_type_symbol: \"bolt.fill\""))
        #expect(contents.contains("editorial_type_color: \"#FF3B30\""))
        #expect(contents.contains("editorial_date: \"2026-08-26\""))
        #expect(contents.hasSuffix("---\n\nPublished article"))
    }

    @Test("Markdown library lists, reloads, and updates an identified draft")
    func markdownLibraryRoundTripsIdentifiedDraft() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialDraftLibraryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let draftID = UUID()
        let first = try EditorialDraftPublisher.publish(
            draft: EditorialDraftSnapshot(
                title: "Library article",
                deck: "A reusable deck",
                body: "First Markdown body",
                revision: 1
            ),
            draftID: draftID,
            targetRelativePath: nil,
            workspaceRoot: root.path,
            metadata: EditorialDeskMetadata(
                section: EditorialDeskSection(name: "Blog", systemImage: "newspaper"),
                type: nil
            )
        )
        let library = EditorialDraftLibraryService()

        let descriptors = try await library.list(workspaceRoot: root.path)
        let loaded = try await library.load(
            relativePath: first.relativePath,
            workspaceRoot: root.path
        )

        #expect(descriptors.map(\.relativePath) == [first.relativePath])
        #expect(descriptors.first?.isEditorialDraft == true)
        #expect(loaded.draftID == draftID)
        #expect(loaded.draft.title == "Library article")
        #expect(loaded.draft.deck == "A reusable deck")
        #expect(loaded.draft.body == "First Markdown body")
        #expect(loaded.metadata.section?.name == "Blog")

        let updated = try EditorialDraftPublisher.publish(
            draft: EditorialDraftSnapshot(
                title: "Library article",
                deck: "A reusable deck",
                body: "Updated Markdown body",
                revision: 2
            ),
            draftID: draftID,
            targetRelativePath: first.relativePath,
            workspaceRoot: root.path
        )
        let reloaded = try await library.load(
            relativePath: updated.relativePath,
            workspaceRoot: root.path
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )

        #expect(files.count == 1)
        #expect(reloaded.draftID == draftID)
        #expect(reloaded.draft.body == "Updated Markdown body")
    }

    @Test("publication receipt is a native timeline block")
    @MainActor
    func publicationReceiptUsesNativeTimelineBlock() {
        let timeline = ChatTimelineStore()
        let publication = EditorialPublicationBlock(
            draftID: UUID(),
            workspaceRoot: "/tmp/workspace",
            relativePath: "Article.md",
            fileName: "Article.md",
            wordCount: 42
        )

        timeline.presentEditorialPublication(publication)

        #expect(timeline.blocks.count == 1)
        #expect(timeline.blocks[0].kind == .editorialPublication)
        #expect(timeline.blocks[0].editorialPublication == publication)
        #expect(timeline.blocks.allSatisfy { $0.kind != .user && $0.kind != .assistant })
    }

    @Test("publication receipt survives stored block encoding")
    func publicationReceiptPersistsAsStructuredData() throws {
        let publication = EditorialPublicationBlock(
            draftID: UUID(),
            workspaceRoot: "/tmp/workspace",
            relativePath: "Articles/Article.md",
            fileName: "Article.md",
            wordCount: 24
        )
        let stored = StoredBlock(
            kind: ChatBlockKind.editorialPublication.rawValue,
            text: publication.fileName,
            editorialPublication: publication
        )

        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredBlock.self, from: data)

        #expect(decoded.kind == ChatBlockKind.editorialPublication.rawValue)
        #expect(decoded.editorialPublication == publication)
    }

    @Test("desk dependencies expose only a native publication receipt port")
    @MainActor
    func dependenciesKeepPublicationReceiptBehindAFeaturePort() async {
        let presenter = RecordingEditorialPublicationPresenter()
        let receipt = EditorialPublicationBlock(
            draftID: UUID(),
            workspaceRoot: "/tmp/workspace",
            relativePath: "Published.md",
            fileName: "Published.md",
            wordCount: 12
        )
        let dependencies = EditorialDeskDependencies(
            modelClient: EditorialDeskTestModelClient(),
            sourceService: EditorialSourceService(),
            publicationService: EditorialPublicationService(),
            draftLibrary: EditorialDraftLibraryService(),
            receiptPresenter: presenter
        )

        await dependencies.receiptPresenter.present(receipt)

        #expect(presenter.publications == [receipt])
    }

    @Test("cancellation waits for the backend and ignores a late completion")
    @MainActor
    func cancellationWaitsForBackendUnwind() async {
        let client = ControlledEditorialDeskModelClient()
        let viewModel = EditorialDeskViewModel(
            workspaceRoot: "",
            modelClient: client
        )
        let snapshot = EditorialDraftSnapshot(
            title: "Draft",
            deck: "",
            body: "Body",
            revision: 1
        )

        viewModel.run(action: .verifyFacts, snapshot: snapshot)
        var isWaiting = await client.isWaiting
        for _ in 0..<20 where !isWaiting {
            await Task.yield()
            isWaiting = await client.isWaiting
        }
        #expect(isWaiting)

        viewModel.cancelOperation()
        #expect(viewModel.operationPhase == .cancelling)
        await client.resolve(
            EditorialResult(revisedDocument: "Late result", findings: [], summary: "late")
        )
        for _ in 0..<20 where viewModel.operationPhase == .cancelling {
            await Task.yield()
        }

        #expect(viewModel.operationPhase == .idle)
        #expect(viewModel.result == nil)
        #expect(viewModel.modelError == EditorialModelError.cancelled.localizedDescription)
    }

    @Test("a draft snapshot remains stable after the editor changes")
    @MainActor
    func draftSnapshotCapturesTheAdmittedValues() async {
        let viewModel = EditorialDeskViewModel(workspaceRoot: "")
        viewModel.updateTitle("Original title")
        viewModel.updateBody("Original body")
        let snapshot = viewModel.makeDraftSnapshot()

        viewModel.updateTitle("Changed title")
        viewModel.updateBody("Changed body")

        let observed = await EditorialDraftSnapshotProbe().observe(snapshot)

        #expect(observed.title == "Original title")
        #expect(observed.body == "Original body")
        #expect(observed.revision < viewModel.makeDraftSnapshot().revision)
    }

    @Test("publication writes once and presents one native receipt")
    @MainActor
    func publicationWritesAndPresentsOneReceipt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialPublicationReceiptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let presenter = RecordingEditorialPublicationPresenter()
        let coordinator = EditorialPublicationCoordinator(
            publicationService: EditorialPublicationService(),
            receiptPresenter: presenter
        )
        let draftID = UUID()
        let request = EditorialPublicationRequest(
            draft: EditorialDraftSnapshot(
                title: "Published article",
                deck: "",
                body: "Body",
                revision: 1
            ),
            draftID: draftID,
            workspaceRoot: root.path,
            metadata: .empty
        )

        let attempt = await coordinator.publish(request)
        guard case .completed(let receipt) = attempt else {
            #expect(Bool(false))
            return
        }
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)

        #expect(files.count == 1)
        #expect(receipt.draftID == draftID)
        #expect(presenter.publications.count == 1)
        #expect(presenter.publications.first?.fileName == receipt.fileName)
    }

    @Test("publish creates a temporary name when the title is empty")
    func publisherFallsBackToTemporaryName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorialTemporaryPublicationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let publication = try EditorialDraftPublisher.publish(
            draft: EditorialDraftSnapshot(
                title: "   ",
                body: "Untitled draft",
                revision: 1
            ),
            draftID: UUID(),
            targetRelativePath: nil,
            workspaceRoot: root.path,
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(publication.fileName.hasPrefix("Untitled-Draft-1970-01-01-"))
        #expect(publication.fileName.hasSuffix(".md"))
        #expect(FileManager.default.fileExists(atPath: publication.url.path))
    }
}

private actor EditorialDraftSnapshotProbe {
    func observe(_ snapshot: EditorialDraftSnapshot) -> EditorialDraftSnapshot {
        snapshot
    }
}

private actor ControlledEditorialDeskModelClient: EditorialModelClient {
    private var continuation: CheckedContinuation<EditorialResult, Error>?

    var isWaiting: Bool {
        continuation != nil
    }

    func perform(_ request: EditorialRequest) async throws -> EditorialResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ result: EditorialResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func cancel() async {}
}

private actor EditorialDeskTestModelClient: EditorialModelClient {
    func perform(_ request: EditorialRequest) async throws -> EditorialResult {
        EditorialResult(revisedDocument: nil, findings: [], summary: request.action.rawValue)
    }

    func cancel() async {}
}

private actor DiagnosticEditorialDeskModelClient: EditorialModelClient {
    func perform(_ request: EditorialRequest) async throws -> EditorialResult {
        EditorialResult(
            revisedDraft: EditorialDraft(
                title: "Should not be applied",
                deck: request.draft.deck,
                body: request.draft.body
            ),
            findings: [],
            summary: "Diagnostic result"
        )
    }

    func cancel() async {}
}

@MainActor
private final class RecordingEditorialPublicationPresenter: EditorialPublicationReceiptPresenting {
    private(set) var publications: [EditorialPublicationBlock] = []

    func present(_ publication: EditorialPublicationBlock) async {
        publications.append(publication)
    }
}
