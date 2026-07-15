import Foundation
import Observation

@MainActor
@Observable
final class SessionSearchViewModel {
    var query = ""

    private let conversations: [Conversation]

    init(conversations: [Conversation]) {
        self.conversations = conversations
    }

    var results: [SessionSearchResult] {
        let normalizedQuery = Self.normalized(query)
        let candidates = conversations.map(SessionSearchResult.init)

        if normalizedQuery.isEmpty {
            return Array(
                candidates
                    .sorted { $0.conversation.updatedAt > $1.conversation.updatedAt }
                    .prefix(10)
            )
        }

        return Array(
            candidates
                .compactMap { result -> (SessionSearchResult, Int)? in
                    let title = Self.normalized(result.conversation.title)
                    let workspace = Self.normalized(result.workspaceName)
                    guard title.contains(normalizedQuery) || workspace.contains(normalizedQuery) else {
                        return nil
                    }
                    return (result, Self.rank(query: normalizedQuery, title: title, workspace: workspace))
                }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                    return lhs.0.conversation.updatedAt > rhs.0.conversation.updatedAt
                }
                .prefix(10)
                .map(\.0)
        )
    }

    private static func rank(query: String, title: String, workspace: String) -> Int {
        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        if title.contains(query) { return 2 }
        if workspace.hasPrefix(query) { return 3 }
        return 4
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SessionSearchResult: Identifiable, Sendable, Hashable {
    let conversation: Conversation
    let workspaceName: String

    var id: String { conversation.id }

    init(conversation: Conversation) {
        self.conversation = conversation
        workspaceName = conversation.workspace
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "No workspace"
    }
}
