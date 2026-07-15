import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Session search")
struct SessionSearchViewModelTests {
    @Test("Empty search returns the ten most recent sessions")
    func recentSessionsAreLimitedAndOrdered() {
        let conversations = (0..<12).map { index in
            Conversation(
                id: "\(index)",
                title: "Chat \(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                workspace: "/Work/Project \(index)"
            )
        }
        let viewModel = SessionSearchViewModel(conversations: conversations)

        #expect(viewModel.results.count == 10)
        #expect(viewModel.results.map(\.conversation.id) == (2..<12).reversed().map(String.init))
    }

    @Test("Search matches session and workspace names immediately")
    func matchesTitlesAndWorkspaces() {
        let conversations = [
            Conversation(title: "Fix café layout", workspace: "/Work/Storefront"),
            Conversation(title: "Refactor settings", workspace: "/Work/CaféKit"),
            Conversation(title: "Build diagnostics", workspace: "/Work/Compiler")
        ]
        let viewModel = SessionSearchViewModel(conversations: conversations)

        viewModel.query = "CAFE"

        #expect(viewModel.results.map(\.conversation.title) == [
            "Fix café layout",
            "Refactor settings"
        ])
        #expect(viewModel.results.map(\.workspaceName) == ["Storefront", "CaféKit"])
    }

    @Test("Exact and prefix title matches rank ahead of workspace matches")
    func ranksRelevantResultsFirst() {
        let conversations = [
            Conversation(title: "Unrelated", workspace: "/Work/Search"),
            Conversation(title: "Search sessions", workspace: "/Work/TurboCode"),
            Conversation(title: "Search", workspace: "/Work/Another")
        ]
        let viewModel = SessionSearchViewModel(conversations: conversations)

        viewModel.query = "search"

        #expect(viewModel.results.map(\.conversation.title) == [
            "Search",
            "Search sessions",
            "Unrelated"
        ])
    }
}
