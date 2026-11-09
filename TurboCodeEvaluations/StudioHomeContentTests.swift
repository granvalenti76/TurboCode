import Foundation
import Testing
@testable import TurboCode

/// The Studio home view only prepares a draft and offers artifacts to pick up
/// from. These tests pin that a card never discards what the user typed and
/// which artifacts are offered first.
@Suite("Studio home content")
struct StudioHomeContentTests {
    private static let web = StudioHomeContent.suggestions[0]
    private static let data = StudioHomeContent.suggestions[1]

    @Test("Cards have distinct identities and unfinished drafts")
    func suggestionsAreDistinctStarters() {
        let suggestions = StudioHomeContent.suggestions
        #expect(Set(suggestions.map(\.id)).count == suggestions.count)
        #expect(Set(suggestions.map(\.draft)).count == suggestions.count)
        #expect(suggestions.allSatisfy { $0.draft.hasSuffix(" ") })
    }

    @Test("A card fills an empty composer with its starter")
    func cardFillsEmptyComposer() {
        #expect(StudioHomeContent.draft(afterChoosing: Self.web, current: "  \n") == Self.web.draft)
    }

    @Test("Choosing another card replaces an untouched starter")
    func cardReplacesUntouchedStarter() {
        #expect(StudioHomeContent.draft(afterChoosing: Self.data, current: Self.web.draft) == Self.data.draft)
    }

    @Test("Text the user typed is kept after the starter")
    func cardKeepsTypedText() {
        let result = StudioHomeContent.draft(afterChoosing: Self.web, current: "a pricing table")
        #expect(result == Self.web.draft + "a pricing table")
    }

    @Test("Choosing the same card twice does not repeat its starter")
    func sameCardIsIdempotent() {
        let once = StudioHomeContent.draft(afterChoosing: Self.web, current: "a pricing table")
        #expect(StudioHomeContent.draft(afterChoosing: Self.web, current: once) == once)
    }

    @Test("Each recent session offers its leading artifact before any second one")
    func recentArtifactsSpreadAcrossSessions() {
        let groups = [
            Self.group("old", updatedAt: 100, paths: ["old.pdf"]),
            Self.group("new", updatedAt: 300, paths: ["a.html", "b.png", "c.csv"]),
            Self.group("mid", updatedAt: 200, paths: ["mid.png"]),
        ]

        let recents = StudioHomeContent.recentArtifacts(in: groups, limit: 4)

        #expect(recents.map(\.artifact.relativePath) == ["a.html", "mid.png", "old.pdf", "b.png"])
        #expect(recents.map(\.sessionID) == ["new", "mid", "old", "new"])
    }

    @Test("Recent artifacts are limited, and an empty library offers none")
    func recentArtifactsAreLimited() {
        let groups = [Self.group("only", updatedAt: 1, paths: ["1.txt", "2.txt", "3.txt", "4.txt", "5.txt"])]

        #expect(StudioHomeContent.recentArtifacts(in: groups).count == StudioHomeContent.recentArtifactLimit)
        #expect(StudioHomeContent.recentArtifacts(in: groups, limit: 0).isEmpty)
        #expect(StudioHomeContent.recentArtifacts(in: []).isEmpty)
    }

    private static func group(_ id: String, updatedAt: TimeInterval, paths: [String]) -> CoworkArtifactGroup {
        CoworkArtifactGroup(
            sessionID: id,
            sessionTitle: "Session \(id)",
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            outbox: URL(fileURLWithPath: "/tmp/outbox-\(id)"),
            artifacts: paths.map { CoworkArtifact(relativePath: $0, size: 1) }
        )
    }
}
