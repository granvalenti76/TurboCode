import Observation
import Testing
@testable import TurboCode

@MainActor
@Suite("Chat timeline store")
struct ChatTimelineStoreTests {
    @Test("Response receipts remain ahead of reasoning and assistant output")
    func responseOrderingPreservesToolReceipts() {
        let store = ChatTimelineStore()
        store.beginResponse(
            displayText: "List the workspace",
            placeholderID: "assistant",
            model: "test-model"
        )
        store.presentWorkspaceListing(
            WorkspaceListingBlock(
                toolCallID: "listing",
                path: ".",
                entries: [],
                totalCount: 0,
                isTruncated: false,
                errorMessage: nil
            )
        )
        store.finalizeResponse(
            placeholderID: "assistant",
            assistantBlock: ChatBlock(
                id: "assistant",
                kind: .assistant,
                text: "Done",
                model: "test-model"
            ),
            reasoningBlock: ChatBlock(
                id: "reasoning",
                kind: .reasoning,
                text: "Checked files",
                model: "test-model"
            )
        )

        #expect(
            store.blocks.map(\.kind)
                == [.user, .workspaceListing, .reasoning, .assistant]
        )
        #expect(store.workspaceListingPresentations.map(\.toolCallID) == ["listing"])
    }

    @Test("Restore and reset discard transient response state")
    func restoreAndResetDiscardTransientState() {
        let store = ChatTimelineStore()
        store.beginResponse(
            displayText: "Question",
            placeholderID: "placeholder",
            model: "test-model"
        )
        store.liveReasoning = "Working"
        store.liveAssistant = "Partial"

        store.restore([ChatBlock(id: "saved", kind: .assistant, text: "Saved")])

        #expect(store.blocks.map(\.id) == ["saved"])
        #expect(store.liveReasoning.isEmpty)
        #expect(store.liveAssistant.isEmpty)
        #expect(!store.isFirstMessage)
        #expect(store.activeAssistantPlaceholderID == nil)

        store.reset()
        #expect(store.blocks.isEmpty)
        #expect(store.isFirstMessage)
    }

    @Test("Grouped edits retain first before-state and final after-state")
    func groupedEditsMergeReviewReceipts() throws {
        let store = ChatTimelineStore()
        let change = DiffPatchFileChange(
            path: "TODO.md",
            additions: 1,
            deletions: 1
        )
        store.beginResponse(
            displayText: nil,
            placeholderID: "assistant",
            model: "test-model"
        )

        store.beginDiffPatch(
            id: "first-call",
            editGroupID: "edit-group",
            workspaceRoot: "/tmp/project",
            patch: "first patch",
            files: [change],
            reviewFiles: [
                DiffReviewFileSnapshot(
                    path: "TODO.md",
                    originalText: "before",
                    modifiedText: "middle"
                )
            ],
            status: .running
        )
        store.beginDiffPatch(
            id: "second-call",
            editGroupID: "edit-group",
            workspaceRoot: "/tmp/project",
            patch: "second patch",
            files: [change],
            reviewFiles: [
                DiffReviewFileSnapshot(
                    path: "TODO.md",
                    originalText: "middle",
                    modifiedText: "after"
                )
            ],
            status: .applied
        )

        let receipt = try #require(store.block(id: "edit-group")?.diffPatch)
        #expect(receipt.patches == ["first patch", "second patch"])
        #expect(receipt.files.first?.additions == 2)
        #expect(receipt.files.first?.deletions == 2)
        #expect(receipt.reviewFiles?.first?.originalText == "before")
        #expect(receipt.reviewFiles?.first?.modifiedText == "after")
        #expect(store.blocks.map(\.kind) == [.diffPatch, .assistant])

        #expect(
            store.updateDiffPatch(
                id: "second-call",
                status: .undone,
                errorMessage: nil
            )
        )
        #expect(store.block(id: "edit-group")?.diffPatch?.status == .undone)
    }

    @Test("ChatStore timeline forwarding remains observable")
    func chatStoreTimelineForwardingRemainsObservable() async {
        let store = ChatStore(
            conversationRepository: TimelineConversationRepository()
        )

        await confirmation("Nested timeline mutation is observed") { observed in
            withObservationTracking {
                _ = store.blocks
            } onChange: {
                observed()
            }
            store.blocks.append(ChatBlock(kind: .assistant, text: "Observed"))
        }

        #expect(store.blocks.map(\.text) == ["Observed"])
    }
}

/// A no-op repository keeps façade observation tests isolated from user data.
private struct TimelineConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}
