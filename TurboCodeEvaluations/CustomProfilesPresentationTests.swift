import Testing
@testable import TurboCode

@MainActor
@Suite("Custom Profiles presentation")
struct CustomProfilesPresentationTests {
    @Test("Opening Custom Profiles preserves Connectors underneath the sheet")
    func connectorsRemainTheUnderlyingDestination() {
        let store = ChatStore(conversationRepository: CustomProfilesConversationRepository())
        store.setRoute(.connectors)

        store.setRoute(.skills)

        #expect(store.route == .connectors)
        #expect(store.isCustomProfilesPresented)
    }

    @Test("Dismissing Custom Profiles does not rebuild the underlying destination")
    func dismissalPreservesUnderlyingDestination() {
        let store = ChatStore(conversationRepository: CustomProfilesConversationRepository())
        store.setRoute(.chat)
        store.setRoute(.skills)

        store.isCustomProfilesPresented = false

        #expect(store.route == .chat)
        #expect(!store.isCustomProfilesPresented)
    }

    @Test("Explicit navigation closes the modal presentation")
    func anotherRouteClosesPresentation() {
        let store = ChatStore(conversationRepository: CustomProfilesConversationRepository())
        store.setRoute(.skills)

        store.setRoute(.connectors)

        #expect(store.route == .connectors)
        #expect(!store.isCustomProfilesPresented)
    }
}

private struct CustomProfilesConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}
