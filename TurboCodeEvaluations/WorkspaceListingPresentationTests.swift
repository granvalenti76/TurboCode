import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Workspace listing presentation")
struct WorkspaceListingPresentationTests {
    @Test("Mechanical Markdown listing is removed after native presentation")
    func nativeListingRemovesMechanicalEcho() {
        let listing = makeListing()
        let response = """
        Here are the files in your workspace:

        - `.git` (directory)
        - `Package.swift` (file, 811 bytes, modified: 2026-07-19T10:00:00Z)

        Let me know if you want to inspect any of these files.
        """

        let filtered = NativeToolEchoFilter.filtering(response, workspaceListings: [listing])

        #expect(filtered.isEmpty)
    }

    @Test("File analysis remains visible after native presentation")
    func nativeListingPreservesAnalysis() {
        let listing = makeListing()
        let response = "Package.swift defines the package products and dependencies."

        let filtered = NativeToolEchoFilter.filtering(response, workspaceListings: [listing])

        #expect(filtered == response)
    }

    @Test("Timeline receipt opens its persisted snapshot in the inspector")
    func receiptSelectsInspectorSnapshot() {
        let store = ChatStore(conversationRepository: ListingConversationRepository())
        let listing = makeListing()
        store.blocks = [
            ChatBlock(
                id: "listing-block",
                kind: .workspaceListing,
                text: ".",
                workspaceListing: listing
            )
        ]

        store.reviewWorkspaceListing("listing-block")

        #expect(store.rightPanelMode == .workspaceListing)
        #expect(store.inspectedWorkspaceListingID == "listing-block")
        #expect(store.inspectedWorkspaceListing == listing)
    }

    @Test("Listings saved before inspector metadata still decode")
    func legacyListingDecodesWithoutPresentationMetadata() throws {
        let legacyJSON = """
        {
          "toolCallID": "legacy-call",
          "path": ".",
          "entries": [],
          "totalCount": 0,
          "isTruncated": false,
          "errorMessage": null
        }
        """

        let listing = try JSONDecoder().decode(
            WorkspaceListingBlock.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(listing.capturedAt == nil)
        #expect(listing.workspaceName == nil)
    }

    @Test("A named file follow-up receives the recent listing path")
    func namedFileFollowUpRetainsListingContext() {
        let prompt = WorkspaceListingFollowUpContext.enriching(
            "Cosa contiene Package.swift?",
            blocks: [listingBlock(makeListing())]
        )

        #expect(prompt.contains("recent-workspace-listing"))
        #expect(prompt.contains("Package.swift"))
        #expect(prompt.contains("Never call turbocode_guide for a workspace file"))
        #expect(prompt.hasSuffix("Cosa contiene Package.swift?"))
    }

    @Test("A referential follow-up receives listing context")
    func referentialFollowUpRetainsListingContext() {
        let prompt = WorkspaceListingFollowUpContext.enriching(
            "Apri quel file e spiegamelo",
            blocks: [listingBlock(makeListing())]
        )

        #expect(prompt.contains("Package.swift"))
    }

    @Test("An unrelated turn is not expanded with stale listing metadata")
    func unrelatedTurnDoesNotReceiveListingContext() {
        let request = "Come si ordina un array in Swift?"

        let prompt = WorkspaceListingFollowUpContext.enriching(
            request,
            blocks: [listingBlock(makeListing())]
        )

        #expect(prompt == request)
    }

    private func makeListing() -> WorkspaceListingBlock {
        WorkspaceListingBlock(
            toolCallID: "tool-call",
            path: ".",
            entries: [
                WorkspaceListingEntry(
                    name: ".git",
                    relativePath: ".git",
                    kind: .directory,
                    sizeBytes: nil,
                    modifiedAt: "2026-07-19T10:00:00Z",
                    fileExtension: nil
                ),
                WorkspaceListingEntry(
                    name: "Package.swift",
                    relativePath: "Package.swift",
                    kind: .file,
                    sizeBytes: 811,
                    modifiedAt: "2026-07-19T10:00:00Z",
                    fileExtension: "swift"
                )
            ],
            totalCount: 2,
            isTruncated: false,
            errorMessage: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            workspaceName: "TurboCode"
        )
    }

    private func listingBlock(_ listing: WorkspaceListingBlock) -> ChatBlock {
        ChatBlock(
            id: "listing-block",
            kind: .workspaceListing,
            text: listing.path,
            workspaceListing: listing
        )
    }
}

/// Keeps inspector-selection tests isolated from the user's persisted sessions.
private struct ListingConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}
