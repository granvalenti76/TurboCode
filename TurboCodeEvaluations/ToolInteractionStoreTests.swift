import Observation
import Testing
@testable import TurboCode

@MainActor
@Suite("Tool interaction store")
struct ToolInteractionStoreTests {
    @Test("Approvals are deduplicated and consumed in FIFO order")
    func approvalsAreFIFOAndDeduplicated() throws {
        let store = ToolInteractionStore()
        let first = approval(id: "first")
        let second = approval(id: "second")

        store.enqueueApproval(first)
        store.enqueueApproval(second)
        store.enqueueApproval(second)

        #expect(try #require(store.takePendingApproval()).id == "first")
        #expect(try #require(store.takePendingApproval()).id == "second")
        #expect(store.takePendingApproval() == nil)
    }

    @Test("Dismissing a queued approval preserves the remaining order")
    func dismissingQueuedApprovalPreservesOrder() throws {
        let store = ToolInteractionStore()
        store.enqueueApproval(approval(id: "first"))
        store.enqueueApproval(approval(id: "removed"))
        store.enqueueApproval(approval(id: "last"))

        store.dismissApproval(id: "removed")

        #expect(try #require(store.takePendingApproval()).id == "first")
        #expect(try #require(store.takePendingApproval()).id == "last")
        #expect(store.pendingApproval == nil)
    }

    @Test("Stopping drains visible and queued approvals together")
    func stoppingDrainsEveryApproval() {
        let store = ToolInteractionStore()
        store.enqueueApproval(approval(id: "visible"))
        store.enqueueApproval(approval(id: "queued"))

        let stopped = store.takeAllApprovals()

        #expect(stopped.map(\.id) == ["visible", "queued"])
        #expect(store.pendingApproval == nil)
        #expect(store.takePendingApproval() == nil)
    }

    @Test("Beginning an existing activity replaces and promotes it")
    func beginningExistingActivityReplacesAndPromotesIt() {
        let store = ToolInteractionStore()
        store.beginActivity(
            id: "first",
            toolName: "ripgrep",
            summary: "Old summary"
        )
        store.beginActivity(id: "second", summary: "Second")
        store.beginActivity(
            id: "first",
            toolName: "ripgrep",
            summary: "Updated summary"
        )

        #expect(store.activities.map(\.id) == ["second", "first"])
        #expect(store.activeActivity?.summary == "Updated summary")
        #expect(store.activeActivity?.toolName == "ripgrep")

        store.endActivity(id: "first")
        #expect(store.activeActivity?.id == "second")

        store.clearActivities()
        #expect(store.activities.isEmpty)
    }

    @Test("Ripgrep activity describes the concrete search without raw payload noise")
    func ripgrepActivitySummaryUsesInvocationDetails() {
        let search = RipgrepActivitySummary.make(
            action: "search",
            pattern: "SessionStore",
            path: "Sources/UI",
            filePattern: "*.swift",
            filesOnly: false
        )
        let discovery = RipgrepActivitySummary.make(
            action: "files",
            pattern: nil,
            path: ".",
            filePattern: "*.json",
            filesOnly: nil
        )
        let fileMatches = RipgrepActivitySummary.make(
            action: "search",
            pattern: "TODO\nFIXME",
            path: ".",
            filePattern: nil,
            filesOnly: true
        )

        #expect(search == "Searching for “SessionStore” · *.swift in Sources/UI")
        #expect(discovery == "Finding *.json files")
        #expect(fileMatches == "Finding files containing “TODO FIXME”")
    }

    @Test("ChatStore approval forwarding remains observable")
    func chatStoreApprovalForwardingRemainsObservable() async {
        let store = ChatStore(
            conversationRepository: ToolInteractionConversationRepository()
        )

        await confirmation("Nested approval mutation is observed") { observed in
            withObservationTracking {
                _ = store.pendingApproval
            } onChange: {
                observed()
            }
            store.presentApproval(approval(id: "observed"))
        }

        #expect(store.pendingApproval?.id == "observed")
    }

    @Test("ChatStore activity forwarding remains observable")
    func chatStoreActivityForwardingRemainsObservable() async {
        let store = ChatStore(
            conversationRepository: ToolInteractionConversationRepository()
        )

        await confirmation("Nested activity mutation is observed") { observed in
            withObservationTracking {
                _ = store.activeToolActivity
            } onChange: {
                observed()
            }
            // Seed the bounded owner directly; the façade only projects
            // activity state for consumers.
            store.toolInteractionStore.activities.append(
                ToolActivity(id: "observed", summary: "Reading workspace")
            )
        }

        #expect(store.activeToolActivity?.id == "observed")
    }

    private func approval(id: String) -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            operation: "write",
            path: "/tmp/\(id).txt",
            summary: "Write \(id).txt"
        )
    }
}

/// A no-op repository prevents the forwarding test from touching persisted
/// user conversations while constructing the production ChatStore façade.
private struct ToolInteractionConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}
