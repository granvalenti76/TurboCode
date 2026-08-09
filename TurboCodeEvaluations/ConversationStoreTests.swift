import Foundation
import Observation
import Testing
@testable import TurboCode

@MainActor
@Suite("Conversation store")
struct ConversationStoreTests {
    @Test("Catalog filters by archive, project, and search before sorting")
    func catalogFiltersAndSortsThreads() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let store = ConversationStore(repository: ConversationStoreRepository())
        store.threads = [
            Conversation(
                id: "archived",
                title: "Archived TurboCode",
                updatedAt: newer,
                isArchived: true,
                workspace: "/Work/TurboCode"
            ),
            Conversation(
                id: "pinned",
                title: "Pinned TurboCode",
                updatedAt: older,
                isPinned: true,
                workspace: "/Work/TurboCode"
            ),
            Conversation(
                id: "recent",
                title: "Recent TurboCode",
                updatedAt: newer,
                workspace: "/Work/TurboCode"
            ),
            Conversation(
                id: "other",
                title: "Other project",
                updatedAt: newer,
                workspace: "/Work/Elsewhere"
            )
        ]
        store.search = "turbocode"

        #expect(
            store.sortedThreads(selectedProject: "TurboCode").map(\.id)
                == ["pinned", "recent"]
        )

        store.showsArchivedThreads = true
        #expect(
            store.sortedThreads(selectedProject: "TurboCode").map(\.id)
                == ["pinned", "archived", "recent"]
        )
    }

    @Test("Metadata mutations preserve identity and update the catalog")
    func metadataMutationsUpdateCatalog() {
        let store = ConversationStore(repository: ConversationStoreRepository())
        store.threads = [Conversation(id: "thread", title: "Original")]

        store.renameThread(id: "thread", title: "Renamed")
        store.pinThread(id: "thread", pinned: true)
        store.archiveThread(id: "thread")

        #expect(store.threads.first?.title == "Renamed")
        #expect(store.threads.first?.isPinned == true)
        #expect(store.threads.first?.isArchived == true)

        store.restoreThread(id: "thread")
        #expect(store.threads.first?.isArchived == false)
    }

    @Test("Metadata persistence preserves an inactive thread timeline")
    func metadataPersistencePreservesInactiveTimeline() throws {
        let originalConversation = Conversation(
            id: "thread",
            title: "Original",
            workspace: "/Work/TurboCode"
        )
        let originalBlock = ChatBlock(kind: .assistant, text: "Keep this transcript")
        let repository = RecordingConversationStoreRepository(
            snapshots: [
                ConversationSnapshot(
                    conversation: originalConversation,
                    modelBackend: ModelBackend.foundationApple.rawValue,
                    blocks: [originalBlock],
                    transcript: nil
                )
            ]
        )
        let store = ConversationStore(repository: repository)
        store.threads = [
            Conversation(
                id: "thread",
                title: "Renamed",
                isPinned: true,
                isArchived: true,
                workspace: "/Work/TurboCode",
                mode: .plan
            )
        ]

        try store.persistMetadata(id: "thread")
        let saved = try #require(repository.snapshots["thread"])

        #expect(saved.conversation.title == "Renamed")
        #expect(saved.conversation.isPinned)
        #expect(saved.conversation.isArchived)
        #expect(saved.conversation.mode == .plan)
        #expect(saved.modelBackend == ModelBackend.foundationApple.rawValue)
        #expect(saved.blocks == [originalBlock])
    }

    @Test("ChatStore conversation forwarding remains observable")
    func chatStoreForwardingRemainsObservable() async {
        let store = ChatStore(conversationRepository: ConversationStoreRepository())

        await confirmation("Nested catalog mutation is observed") { observed in
            withObservationTracking {
                _ = store.threads
            } onChange: {
                observed()
            }
            await store.createThread(title: "Observed")
        }

        #expect(store.threads.map(\.title) == ["Observed"])
        #expect(store.activeThreadId == store.threads.first?.id)
    }
}

/// A no-op boundary keeps catalog tests independent from the user's persisted
/// sessions while still exercising the production dependency shape.
private struct ConversationStoreRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}

/// A synchronous recording repository verifies catalog-only writes without
/// touching the user's on-disk session directory.
private final class RecordingConversationStoreRepository: ConversationRepository, @unchecked Sendable {
    var snapshots: [String: ConversationSnapshot]

    init(snapshots: [ConversationSnapshot]) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.conversation.id, $0) })
    }

    func save(_ snapshot: ConversationSnapshot) throws {
        snapshots[snapshot.conversation.id] = snapshot
    }

    func load(id: String) throws -> ConversationSnapshot? {
        snapshots[id]
    }

    func list() throws -> [ConversationSnapshot] {
        Array(snapshots.values)
    }

    func delete(id: String) throws {
        snapshots.removeValue(forKey: id)
    }
}
