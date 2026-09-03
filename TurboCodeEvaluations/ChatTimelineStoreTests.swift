import Foundation
import Observation
import Testing
@testable import TurboCode

@MainActor
@Suite("Chat timeline store")
struct ChatTimelineStoreTests {
    @Test("Runtime snapshots are projected without moving lifecycle ownership")
    func projectsRuntimeSnapshot() {
        let store = ChatTimelineStore()
        let turnID = TurnID(rawValue: "timeline-runtime")
        let snapshot = RuntimeSnapshot(
            activeThreadID: "thread-1",
            backend: .foundationApple,
            turn: TurnState(
                id: turnID,
                phase: .streaming,
                startedAt: Date(timeIntervalSince1970: 100)
            ),
            isQuiescing: true
        )

        store.applyRuntimeSnapshot(snapshot)

        #expect(store.runtimeSnapshot == snapshot)
        #expect(store.runtimeSnapshot?.turn?.id == turnID)
        #expect(store.runtimeSnapshot?.isQuiescing == true)
        #expect(store.blocks.isEmpty)
    }

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

    @Test("Steering delivery splits cumulative assistant output once")
    func steeringDeliverySplitsCumulativeOutput() {
        let store = ChatTimelineStore()
        store.beginResponse(
            displayText: "Initial request",
            placeholderID: "response-1",
            model: "test-model"
        )
        store.liveAssistant = "Already completed"
        store.liveReasoning = "Earlier reasoning"
        let requestID = SteeringRequestID(rawValue: "request-1")
        let deliveryID = SteeringDeliveryID(rawValue: "delivery-1")

        let newPlaceholder = store.beginSteeringSegment(
            displayText: "Please continue carefully",
            metadata: SteeringDeliveryMetadata(
                requestIDs: [requestID],
                deliveryID: deliveryID,
                providerTurnID: "server-turn-1"
            ),
            model: "test-model"
        )

        #expect(newPlaceholder != nil)
        #expect(store.blocks.map(\.kind) == [
            .user, .reasoning, .assistant, .user, .assistant
        ])
        #expect(store.blocks[2].text == "Already completed")
        #expect(store.blocks[3].steeringDelivery?.deliveryID == deliveryID)
        #expect(store.activeAssistantPlaceholderID == newPlaceholder)
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

    @Test("Stale response cleanup cannot clear a newer response")
    func staleResponseCleanupPreservesCurrentResponse() {
        let store = ChatTimelineStore()
        store.beginResponse(
            displayText: "Old request",
            placeholderID: "old-response",
            model: "test-model"
        )
        store.beginResponse(
            displayText: "New request",
            placeholderID: "new-response",
            model: "test-model"
        )
        store.liveAssistant = "New partial answer"
        store.liveReasoning = "New reasoning"

        // A late settlement from the superseded turn must not clean the
        // transient state that belongs to the currently active response.
        store.finishResponse(placeholderID: "old-response")

        #expect(store.activeAssistantPlaceholderID == "new-response")
        #expect(store.liveAssistant == "New partial answer")
        #expect(store.liveReasoning == "New reasoning")
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
            // Seed the bounded timeline owner; the façade only projects it.
            store.timelineStore.blocks.append(
                ChatBlock(kind: .assistant, text: "Observed")
            )
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
