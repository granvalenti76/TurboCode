import Testing
@testable import TurboCode

@MainActor
@Suite("Sidebar conversation disclosure")
struct SidebarConversationDisclosureTests {
    @Test("The initial sidebar collection contains at most five chats")
    func initialCollectionIsLimitedToFive() {
        let threads = makeThreads(count: 8)

        let visible = SidebarConversationDisclosure.visibleIDs(in: threads, limit: 5)

        #expect(visible == threads.prefix(5).map(\.id))
    }

    @Test("Progressive disclosure reveals chats in five-row batches")
    func disclosureAdvancesByOneBatch() {
        #expect(SidebarConversationDisclosure.nextLimit(current: 5, total: 13) == 10)
        #expect(SidebarConversationDisclosure.nextLimit(current: 10, total: 13) == 13)
    }

    @Test("Opening a hidden search result reveals its containing batch")
    func hiddenSelectionBecomesVisible() {
        let threads = makeThreads(count: 12)

        let limit = SidebarConversationDisclosure.limitRevealing(
            threadID: "thread-7",
            in: threads,
            current: 5
        )

        #expect(limit == 10)
    }

    @Test("Leaving Tools opens the restored conversation in one final state")
    func utilityToConversationNavigationRestoresBeforeShowingChat() async {
        let conversation = Conversation(id: "restored", title: "Restored")
        let restoredBlock = ChatBlock(kind: .assistant, text: "Final timeline")
        let repository = SidebarConversationRepository(
            snapshot: ConversationSnapshot(
                conversation: conversation,
                modelBackend: "llama",
                blocks: [restoredBlock],
                transcript: nil
            )
        )
        let store = ChatStore(conversationRepository: repository)
        // Seed the bounded stores directly; navigation itself remains command
        // based through openThread and setRoute.
        store.conversationStore.threads = [conversation]
        store.timelineStore.restore([
            ChatBlock(kind: .assistant, text: "Stale timeline")
        ])
        store.workbenchStore.route = .tools

        await store.openThread(conversation.id)

        #expect(store.route == .chat)
        #expect(store.activeThreadId == conversation.id)
        #expect(store.blocks.map(\.text) == ["Final timeline"])
    }

    private func makeThreads(count: Int) -> [Conversation] {
        (0..<count).map { index in
            Conversation(id: "thread-\(index)", title: "Thread \(index)")
        }
    }
}

private struct SidebarConversationRepository: ConversationRepository {
    let snapshot: ConversationSnapshot

    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? {
        snapshot.conversation.id == id ? snapshot : nil
    }
    func list() throws -> [ConversationSnapshot] { [snapshot] }
    func delete(id: String) throws {}
}
