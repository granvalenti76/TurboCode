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

    @Test("Deleting an active persisted chat selects a valid unsaved draft")
    func activeDeletionSelectsUnsavedDraft() async {
        let deleted = Conversation(id: "deleted", title: "Deleted")
        let draft = Conversation(id: "draft", title: "Unsaved draft")
        let repository = DeletionConversationRepository(
            snapshots: [makeSnapshot(deleted)]
        )
        let store = ChatStore(conversationRepository: repository)
        store.conversationStore.threads = [deleted, draft]
        store.conversationStore.activeThreadID = deleted.id
        store.timelineStore.restore([
            ChatBlock(kind: .assistant, text: "Deleted timeline")
        ])

        await store.deleteThread(id: deleted.id)

        #expect(store.threads.map(\.id) == [draft.id])
        #expect(store.activeThreadId == draft.id)
        #expect(store.agentRuntimeProjectionStore.snapshot.activeThreadID == draft.id)
        #expect(store.blocks.isEmpty)
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

    @Test("Restoring a session installs one matching runtime and UI context")
    func restoringSessionInstallsMatchingContext() async {
        let conversation = Conversation(
            id: "context",
            title: "Restored context",
            workspace: "/Work/Restored"
        )
        let repository = DeletionConversationRepository(
            snapshots: [
                ConversationSnapshot(
                    conversation: conversation,
                    modelBackend: ModelBackend.foundationApple.rawValue,
                    blocks: [ChatBlock(kind: .assistant, text: "Durable timeline")],
                    transcript: nil
                )
            ]
        )
        let store = ChatStore(conversationRepository: repository)
        await store.restoreSessions()
        store.timelineStore.restore([
            ChatBlock(kind: .assistant, text: "Previous timeline")
        ])
        store.workbenchStore.rightPanelMode = .workspaceListing
        store.workbenchStore.inspectedWorkspaceListingID = "previous-receipt"

        await store.restoreSession(id: conversation.id)

        #expect(store.activeThreadId == conversation.id)
        #expect(store.agentRuntimeProjectionStore.snapshot.activeThreadID == conversation.id)
        #expect(store.workspaceRoot == "/Work/Restored")
        #expect(store.blocks.map(\.text) == ["Durable timeline"])
        #expect(store.workbenchStore.rightPanelMode == nil)
        #expect(store.workbenchStore.inspectedWorkspaceListingID == nil)
    }

    @Test("Deleting the active chat never adopts an unreadable successor")
    func activeDeletionSkipsUnreadableSuccessor() async {
        let deleted = Conversation(id: "deleted", title: "Deleted")
        let broken = Conversation(id: "broken", title: "Broken")
        let repository = DeletionConversationRepository(
            snapshots: [makeSnapshot(deleted), makeSnapshot(broken)],
            unreadableIDs: [broken.id]
        )
        let store = ChatStore(conversationRepository: repository)
        store.conversationStore.threads = [deleted, broken]
        store.conversationStore.activeThreadID = deleted.id
        store.timelineStore.restore([
            ChatBlock(kind: .assistant, text: "Deleted timeline")
        ])

        await store.deleteThread(id: deleted.id)
        // A later context change runs the persistence checkpoint.
        await store.createThread()

        #expect(store.threads.contains { $0.id == broken.id })
        #expect(store.activeThreadId != broken.id)
        #expect(store.presentationViewModel.errorMessage?.contains("Could not open") == true)
        #expect(!repository.savedIDs.contains(broken.id))
    }

    @Test("Opening an unreadable session keeps the current chat and its file")
    func unreadableRestoreKeepsCurrentChat() async {
        let current = Conversation(id: "current", title: "Current")
        let broken = Conversation(id: "broken", title: "Broken")
        let repository = DeletionConversationRepository(
            snapshots: [makeSnapshot(current), makeSnapshot(broken)],
            unreadableIDs: [broken.id]
        )
        let store = ChatStore(conversationRepository: repository)
        store.conversationStore.threads = [current, broken]
        store.conversationStore.activeThreadID = current.id
        store.timelineStore.restore([
            ChatBlock(kind: .assistant, text: "Current timeline")
        ])

        await store.restoreSession(id: broken.id)

        #expect(store.activeThreadId == current.id)
        #expect(store.blocks.map(\.text) == ["Current timeline"])
        let message = store.presentationViewModel.errorMessage
        #expect(message?.contains("Could not open “Broken”") == true)

        // Even if a caller forces the unreadable thread active, the session
        // coordinator refuses to save the visible timeline over its file.
        store.conversationStore.activeThreadID = broken.id
        store.timelineStore.reset()
        await store.persistSession(for: broken.id)
        #expect(!repository.savedIDs.contains(broken.id))
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
    case unreadable
}

/// Locked storage lets two ChatStore instances exercise the same persistence
/// boundary while satisfying the repository's cross-actor Sendable contract.
private final class DeletionConversationRepository: ConversationRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: ConversationSnapshot]
    private var recordedSaveIDs: [String] = []
    private let deletionFailure: DeletionRepositoryError?
    /// IDs whose stored file exists but cannot be decoded.
    private let unreadableIDs: Set<String>

    init(
        snapshots: [ConversationSnapshot],
        deletionFailure: DeletionRepositoryError? = nil,
        unreadableIDs: Set<String> = []
    ) {
        self.snapshots = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.conversation.id, $0) }
        )
        self.deletionFailure = deletionFailure
        self.unreadableIDs = unreadableIDs
    }

    var savedIDs: [String] {
        lock.withLock { recordedSaveIDs }
    }

    func save(_ snapshot: ConversationSnapshot) throws {
        lock.withLock {
            recordedSaveIDs.append(snapshot.conversation.id)
            snapshots[snapshot.conversation.id] = snapshot
        }
    }

    func load(id: String) throws -> ConversationSnapshot? {
        if unreadableIDs.contains(id) { throw DeletionRepositoryError.unreadable }
        return lock.withLock { snapshots[id] }
    }

    func list() throws -> [ConversationSnapshot] {
        lock.withLock { Array(snapshots.values) }
    }

    func delete(id: String) throws {
        if let deletionFailure { throw deletionFailure }
        lock.withLock { _ = snapshots.removeValue(forKey: id) }
    }
}
