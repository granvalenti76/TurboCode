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
