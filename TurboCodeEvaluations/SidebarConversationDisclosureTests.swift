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

    private func makeThreads(count: Int) -> [Conversation] {
        (0..<count).map { index in
            Conversation(id: "thread-\(index)", title: "Thread \(index)")
        }
    }
}
