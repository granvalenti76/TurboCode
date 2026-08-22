import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Conversation deletion")
struct ConversationDeletionTests {
    @Test("Deleted conversations do not return after a simulated relaunch")
    func deletionRemovesPersistedSession() async throws {
        let conversation = Conversation(id: "persisted", title: "Persisted")
        let repository = DeletionConversationRepository(
            snapshots: [makeSnapshot(conversation)]
        )
        let store = ChatStore(conversationRepository: repository)
        await store.restoreSessions()

        await store.deleteThread(id: conversation.id)

        #expect(store.threads.isEmpty)
        #expect(try repository.load(id: conversation.id) == nil)

        // A fresh store models the next application launch and reads only the
        // durable repository, not the previous process's in-memory list.
        let relaunchedStore = ChatStore(conversationRepository: repository)
        await relaunchedStore.restoreSessions()
        #expect(relaunchedStore.threads.isEmpty)
    }

    @Test("A persistence failure keeps the conversation visible")
    func failedDeletionDoesNotPretendToSucceed() async {
        let conversation = Conversation(id: "protected", title: "Protected")
        let repository = DeletionConversationRepository(
            snapshots: [makeSnapshot(conversation)],
            deletionFailure: .denied
        )
        let store = ChatStore(conversationRepository: repository)
        // Seed the owning catalog directly; the public façade is read-only.
        store.conversationStore.threads = [conversation]

        await store.deleteThread(id: conversation.id)

        #expect(store.threads.map(\.id) == [conversation.id])
        #expect(
            store.presentationViewModel.errorMessage?
                .contains("Could not delete the conversation") == true
        )
    }

    @Test("Deleting the active conversation restores the next timeline")
    func activeDeletionRestoresNextConversation() async {
        let deleted = Conversation(id: "deleted", title: "Deleted")
        let retained = Conversation(id: "retained", title: "Retained")
        let retainedSnapshot = ConversationSnapshot(
            conversation: retained,
            modelBackend: "llama",
            blocks: [ChatBlock(kind: .assistant, text: "Retained timeline")],
            transcript: nil
        )
        let repository = DeletionConversationRepository(
            snapshots: [makeSnapshot(deleted), retainedSnapshot]
        )
        let store = ChatStore(conversationRepository: repository)
        // Test setup bypasses UI commands while keeping production projections
        // read-only and the bounded stores explicit.
        store.conversationStore.threads = [deleted, retained]
        store.conversationStore.activeThreadID = deleted.id
        store.timelineStore.restore([
            ChatBlock(kind: .assistant, text: "Deleted timeline")
        ])

        await store.deleteThread(id: deleted.id)

        #expect(store.activeThreadId == retained.id)
        #expect(store.blocks.map(\.text) == ["Retained timeline"])
        #expect(store.threads.map(\.id) == [retained.id])
    }

    @Test("Opening persisted threads restores the matching timeline")
    func openingPersistedThreadsRestoresMatchingTimeline() async {
        let first = Conversation(id: "first", title: "First")
        let second = Conversation(id: "second", title: "Second")
        let repository = DeletionConversationRepository(
            snapshots: [
                ConversationSnapshot(
                    conversation: first,
                    modelBackend: ModelBackend.foundationApple.rawValue,
                    blocks: [ChatBlock(kind: .assistant, text: "First saved")],
                    transcript: nil
                ),
                ConversationSnapshot(
                    conversation: second,
                    modelBackend: ModelBackend.foundationApple.rawValue,
                    blocks: [ChatBlock(kind: .assistant, text: "Second saved")],
                    transcript: nil
                )
            ]
        )
        let store = ChatStore(conversationRepository: repository)
        await store.restoreSessions()

        await store.openThread(first.id)
        #expect(store.activeThreadId == first.id)
        #expect(store.blocks.map(\.text) == ["First saved"])

        await store.openThread(second.id)
        #expect(store.activeThreadId == second.id)
        #expect(store.blocks.map(\.text) == ["Second saved"])
    }

    private func makeSnapshot(_ conversation: Conversation) -> ConversationSnapshot {
        ConversationSnapshot(
            conversation: conversation,
            modelBackend: "llama",
            blocks: [ChatBlock(kind: .assistant, text: "Saved")],
            transcript: nil
        )
    }
}

private enum DeletionRepositoryError: Error, Sendable {
    case denied
}

/// Locked storage lets two ChatStore instances exercise the same persistence
/// boundary while satisfying the repository's cross-actor Sendable contract.
private final class DeletionConversationRepository: ConversationRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: ConversationSnapshot]
    private let deletionFailure: DeletionRepositoryError?

    init(
        snapshots: [ConversationSnapshot],
        deletionFailure: DeletionRepositoryError? = nil
    ) {
        self.snapshots = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.conversation.id, $0) }
        )
        self.deletionFailure = deletionFailure
    }

    func save(_ snapshot: ConversationSnapshot) throws {
        lock.withLock { snapshots[snapshot.conversation.id] = snapshot }
    }

    func load(id: String) throws -> ConversationSnapshot? {
        lock.withLock { snapshots[id] }
    }

    func list() throws -> [ConversationSnapshot] {
        lock.withLock { Array(snapshots.values) }
    }

    func delete(id: String) throws {
        if let deletionFailure { throw deletionFailure }
        lock.withLock { _ = snapshots.removeValue(forKey: id) }
    }
}
