import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Conversation title regression")
struct ConversationTitleRegressionTests {
    @Test("Generated title updates its initiating conversation after navigation")
    func generatedTitleUsesStableThreadIdentity() {
        let store = ChatStore(conversationRepository: EmptyConversationRepository())
        store.threads = [
            Conversation(id: "initiating", title: "New Chat", workspace: "/Work/First"),
            Conversation(id: "active", title: "New Chat", workspace: "/Work/Second")
        ]
        store.activeThreadId = "active"

        store.applyGeneratedTitle("Refine native sidebar", to: "initiating")

        #expect(store.threads.first(where: { $0.id == "initiating" })?.title == "Refine native sidebar")
        #expect(store.threads.first(where: { $0.id == "active" })?.title == "New Chat")
    }

    @Test("Generated title is visible in global and workspace collections")
    func generatedTitlePropagatesThroughSidebarCollections() {
        let store = ChatStore(conversationRepository: EmptyConversationRepository())
        store.threads = [
            Conversation(id: "session", title: "New Chat", workspace: "/Work/TurboCode")
        ]

        store.applyGeneratedTitle("Fix session titles", to: "session")
        #expect(store.sortedThreads.map(\.title) == ["Fix session titles"])

        store.selectedProject = "TurboCode"
        #expect(store.sortedThreads.map(\.title) == ["Fix session titles"])
    }

    @Test("Generated title does not replace a manual rename")
    func generatedTitlePreservesManualRename() {
        let store = ChatStore(conversationRepository: EmptyConversationRepository())
        store.threads = [Conversation(id: "session", title: "Manual title")]

        store.applyGeneratedTitle("Generated title", to: "session")

        #expect(store.threads.first?.title == "Manual title")
    }
}

/// A no-op persistence boundary keeps title tests deterministic and prevents
/// evaluation runs from reading or writing the user's session directory.
private struct EmptyConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}
