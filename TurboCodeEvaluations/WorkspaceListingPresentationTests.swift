import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Workspace listing presentation")
struct WorkspaceListingPresentationTests {
    @Test("Native Generable structure becomes one complete Core receipt")
    func nativeStructurePreservesTypedListing() throws {
        let generated = GeneratedContent(
            WorkspaceListingToolOutput(
                path: ".",
                entries: [
                    WorkspaceListingToolEntry(
                        name: "Package.swift",
                        relativePath: "Package.swift",
                        kind: WorkspaceListingEntryKind.file.rawValue,
                        sizeBytes: 811,
                        modifiedAt: "2026-07-19T10:00:00Z",
                        fileExtension: "swift"
                    )
                ],
                totalCount: 1,
                isTruncated: false,
                errorMessage: nil
            )
        )
        let call = Transcript.ToolCall(
            id: "native-listing",
            toolName: "list_workspace",
            arguments: GeneratedContent(properties: ["path": "."])
        )
        let output = Transcript.ToolOutput(
            id: call.id,
            toolName: call.toolName,
            segments: [
                .structure(
                    Transcript.StructuredSegment(
                        schemaName: "WorkspaceListingToolOutput",
                        content: generated
                    )
                )
            ]
        )
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

        guard case .workspaceListing(let listing) = ToolReceiptRouter.receipt(
            for: call,
            output: output,
            workspaceName: "TurboCode",
            capturedAt: capturedAt
        ) else {
            Issue.record("Expected a typed workspace-listing receipt")
            return
        }

        #expect(listing.toolCallID == call.id)
        #expect(listing.path == ".")
        #expect(listing.entries.first?.name == "Package.swift")
        #expect(listing.entries.first?.sizeBytes == 811)
        #expect(listing.entries.first?.fileExtension == "swift")
        #expect(listing.capturedAt == capturedAt)
        #expect(listing.workspaceName == "TurboCode")
    }

    @Test("Only a current TurnID projects and deduplicates its widget receipt")
    func runtimeGateOwnsReceiptProjection() async {
        let timeline = ChatTimelineStore()
        let runtime = AgentRuntime()
        let coordinator = ChatResponseCoordinator(
            timeline: timeline,
            toolInteractions: ToolInteractionStore(),
            agentActivity: AgentActivityStore(),
            agentRuntime: runtime,
            llmRuntime: LLMRuntime()
        )
        let activeTurnID = TurnID(rawValue: "active-receipt-turn")
        let request = TurnRequest(
            id: activeTurnID,
            prompt: "List the workspace",
            backend: .llamaServer,
            modelName: "test-model",
            workspaceRoot: "/workspace"
        )
        #expect(await runtime.apply(.started(request)))
        let listing = makeListing()
        let current = ToolResult(
            id: listing.toolCallID,
            turnID: activeTurnID,
            status: .succeeded,
            receipt: .workspaceListing(listing)
        )

        #expect(await coordinator.acceptBackendEvent(.toolFinished(current)))
        #expect(await coordinator.acceptBackendEvent(.toolFinished(current)))
        #expect(timeline.blocks.filter { $0.kind == .workspaceListing }.count == 1)

        let stale = ToolResult(
            id: "stale-tool",
            turnID: TurnID(rawValue: "stale-receipt-turn"),
            status: .succeeded,
            receipt: .workspaceListing(
                WorkspaceListingBlock(
                    toolCallID: "stale-tool",
                    path: "stale",
                    entries: [],
                    totalCount: 0,
                    isTruncated: false,
                    errorMessage: nil
                )
            )
        )
        let acceptedStaleReceipt = await coordinator.acceptBackendEvent(
            .toolFinished(stale)
        )
        #expect(!acceptedStaleReceipt)
        #expect(timeline.blocks.filter { $0.kind == .workspaceListing }.count == 1)
    }

    @Test("Native completion without its admitted start cannot inherit a newer turn")
    func uncorrelatedNativeCompletionIsRejected() async {
        let timeline = ChatTimelineStore()
        let runtime = AgentRuntime()
        let coordinator = ChatResponseCoordinator(
            timeline: timeline,
            toolInteractions: ToolInteractionStore(),
            agentActivity: AgentActivityStore(),
            agentRuntime: runtime,
            llmRuntime: LLMRuntime()
        )
        let request = TurnRequest(
            id: TurnID(rawValue: "newer-turn"),
            prompt: "A newer request",
            backend: .llamaServer,
            modelName: "test-model",
            workspaceRoot: "/workspace"
        )
        #expect(await runtime.apply(.started(request)))
        let call = Transcript.ToolCall(
            id: "old-native-tool",
            toolName: "list_workspace",
            arguments: GeneratedContent(properties: ["path": "."])
        )
        let generated = GeneratedContent(
            WorkspaceListingToolOutput(
                path: ".",
                entries: [],
                totalCount: 0,
                isTruncated: false,
                errorMessage: nil
            )
        )
        let output = Transcript.ToolOutput(
            id: call.id,
            toolName: call.toolName,
            segments: [
                .structure(
                    Transcript.StructuredSegment(
                        schemaName: "WorkspaceListingToolOutput",
                        content: generated
                    )
                )
            ]
        )

        await coordinator.toolFinished(
            call,
            output: output,
            backend: .llamaServer,
            owner: .coordinator,
            workspaceName: "TurboCode"
        )

        #expect(timeline.blocks.allSatisfy { $0.kind != .workspaceListing })
    }

    @Test("Correlated native completion projects its structured receipt")
    func correlatedNativeCompletionProjectsReceipt() async {
        let timeline = ChatTimelineStore()
        let runtime = AgentRuntime()
        let coordinator = ChatResponseCoordinator(
            timeline: timeline,
            toolInteractions: ToolInteractionStore(),
            agentActivity: AgentActivityStore(),
            agentRuntime: runtime,
            llmRuntime: LLMRuntime()
        )
        let request = TurnRequest(
            id: TurnID(rawValue: "native-receipt-turn"),
            prompt: "List the workspace",
            backend: .llamaServer,
            modelName: "test-model",
            workspaceRoot: "/workspace"
        )
        #expect(await runtime.apply(.started(request)))
        let call = Transcript.ToolCall(
            id: "current-native-tool",
            toolName: "list_workspace",
            arguments: GeneratedContent(properties: ["path": "."])
        )
        let output = Transcript.ToolOutput(
            id: call.id,
            toolName: call.toolName,
            segments: [
                .structure(
                    Transcript.StructuredSegment(
                        schemaName: "WorkspaceListingToolOutput",
                        content: GeneratedContent(
                            WorkspaceListingToolOutput(
                                path: ".",
                                entries: [],
                                totalCount: 0,
                                isTruncated: false,
                                errorMessage: nil
                            )
                        )
                    )
                )
            ]
        )

        await coordinator.toolStarted(
            call,
            backend: .llamaServer,
            owner: .coordinator
        )
        await coordinator.toolFinished(
            call,
            output: output,
            backend: .llamaServer,
            owner: .coordinator,
            workspaceName: "TurboCode"
        )

        let listings = timeline.blocks.compactMap(\.workspaceListing)
        #expect(listings.count == 1)
        #expect(listings.first?.toolCallID == call.id)
        #expect(listings.first?.workspaceName == "TurboCode")
    }

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
        store.timelineStore.restore([
            ChatBlock(
                id: "listing-block",
                kind: .workspaceListing,
                text: ".",
                workspaceListing: listing
            )
        ])

        store.reviewWorkspaceListing("listing-block")

        #expect(store.rightPanelMode == .workspaceListing)
        #expect(store.inspectedWorkspaceListingID == "listing-block")
        #expect(store.inspectedWorkspaceListing == listing)
    }

    @Test("Activity receipt reuses the existing native inspector snapshot")
    func activityReceiptSelectsInspectorSnapshot() {
        let store = ChatStore(conversationRepository: ListingConversationRepository())
        let listing = makeListing()
        store.timelineStore.restore([listingBlock(listing)])

        #expect(store.canOpenActivityReceipt(listing.toolCallID))
        #expect(store.openActivityReceipt(listing.toolCallID))
        #expect(store.rightPanelMode == .workspaceListing)
        #expect(store.inspectedWorkspaceListing == listing)
        #expect(!store.openActivityReceipt("missing-receipt"))
    }

    @Test("Click-away dismissal closes only a workspace listing inspector")
    func workspaceListingDismissalIsScoped() {
        let store = ChatStore(conversationRepository: ListingConversationRepository())
        let listing = makeListing()
        store.timelineStore.restore([listingBlock(listing)])
        store.reviewWorkspaceListing("listing-block")

        store.dismissWorkspaceListingInspector()

        #expect(store.rightPanelMode == nil)
        #expect(store.inspectedWorkspaceListingID == nil)

        store.workbenchStore.rightPanelMode = .changes
        store.dismissWorkspaceListingInspector()
        #expect(store.rightPanelMode == .changes)
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
