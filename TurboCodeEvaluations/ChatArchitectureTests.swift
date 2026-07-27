import Observation
import Testing
@testable import TurboCode

@MainActor
@Suite("Chat architecture boundaries")
struct ChatArchitectureTests {
    @Test("Workbench profile presentation preserves the underlying route")
    func workbenchProfilePresentationIsModal() {
        let workbench = WorkbenchStore()
        workbench.route = .tools
        workbench.setRoute(.skills)

        #expect(workbench.route == .tools)
        #expect(workbench.isCustomProfilesPresented)

        workbench.rightPanelMode = .changes
        workbench.setRoute(.settings)
        #expect(workbench.route == .settings)
        #expect(workbench.rightPanelMode == nil)
    }

    @Test("Runtime rejects an incomplete skill command before inference")
    func runtimeRejectsIncompleteSkillCommand() {
        let runtime = ModelRuntimeStore()

        #expect(runtime.resolvedPrompt(for: "/skill") == nil)
        #expect(runtime.resolvedPrompt(for: "plain request") == "plain request")
    }

    @Test("Response coordinator state remains observable through the facade")
    func responseStateForwardsObservation() async {
        let store = ChatStore(
            conversationRepository: ArchitectureConversationRepository()
        )

        await confirmation("Delegation change is observed") { observed in
            withObservationTracking {
                _ = store.isDelegating
            } onChange: {
                observed()
            }
            store.responseCoordinator.delegationChanged(true)
        }

        #expect(store.isDelegating)
    }
}

/// Keeps façade tests isolated from the user's persisted conversation catalog.
private struct ArchitectureConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}
