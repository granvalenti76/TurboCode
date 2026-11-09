import Foundation

/// One capability card on the Studio home view: what Studio can do, and the
/// draft the card leaves in the composer.
nonisolated struct StudioHomeSuggestion: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    /// An unfinished sentence, so the user completes the request instead of
    /// sending a generic one. A card never sends anything by itself.
    let draft: String
}

/// An artifact offered on the Studio home view, with the session that made it.
nonisolated struct StudioRecentArtifact: Identifiable, Sendable, Equatable {
    let sessionID: String
    let sessionTitle: String
    let outbox: URL
    let artifact: CoworkArtifact

    var id: String { "\(sessionID)/\(artifact.id)" }
}

/// What the Studio home view shows above the composer of a new session.
///
/// Studio is the user-visible name of the Cowork domain; the artifact types
/// keep the Cowork name (see PRODUCT.md). Kept free of SwiftUI and of the
/// stores so the choices below can be tested off the main actor.
nonisolated enum StudioHomeContent {
    static let recentArtifactLimit = 3

    /// The cards stay within what the VM boundary allows: building, processing
    /// and generating files. They must not advertise web research or desktop
    /// automation, which PRODUCT.md lists as non-goals.
    static let suggestions: [StudioHomeSuggestion] = [
        StudioHomeSuggestion(
            id: "web",
            title: "Web pages and apps",
            subtitle: "Build it, preview it live",
            systemImage: "macwindow",
            draft: "Build a web page with a live preview: "
        ),
        StudioHomeSuggestion(
            id: "data",
            title: "Data and scripts",
            subtitle: "Clean, analyze, chart",
            systemImage: "chart.bar",
            draft: "Analyze this data and chart the result: "
        ),
        StudioHomeSuggestion(
            id: "documents",
            title: "Documents",
            subtitle: "Reports, PDFs, slides",
            systemImage: "doc.text",
            draft: "Write a document and save it as a PDF: "
        ),
        StudioHomeSuggestion(
            id: "files",
            title: "Your files",
            subtitle: "Read a folder, export results",
            systemImage: "folder",
            draft: "Look at the files in the shared folder and "
        ),
    ]

    /// The composer text after a card is chosen.
    ///
    /// An empty draft, or one that is still another card's untouched starter,
    /// is replaced. Anything the user typed is kept and continues the starter,
    /// because a card must never discard the user's words.
    static func draft(afterChoosing suggestion: StudioHomeSuggestion, current: String) -> String {
        let typed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let isStarter = suggestions.contains {
            $0.draft.trimmingCharacters(in: .whitespacesAndNewlines) == typed
        }
        if typed.isEmpty || isStarter { return suggestion.draft }
        if current.hasPrefix(suggestion.draft) { return current }
        return suggestion.draft + typed
    }

    /// Up to `limit` artifacts to pick up from, most recently used session
    /// first.
    ///
    /// Each session contributes its leading artifact before any session
    /// contributes a second one, so one large outbox cannot hide the others.
    /// Artifacts carry no date of their own; the session's last use and the
    /// library's display order stand in for it.
    static func recentArtifacts(
        in groups: [CoworkArtifactGroup],
        limit: Int = recentArtifactLimit
    ) -> [StudioRecentArtifact] {
        guard limit > 0 else { return [] }
        let ordered = groups.sorted { $0.updatedAt > $1.updatedAt }
        func entries(_ group: CoworkArtifactGroup, _ artifacts: some Sequence<CoworkArtifact>) -> [StudioRecentArtifact] {
            artifacts.map {
                StudioRecentArtifact(
                    sessionID: group.sessionID,
                    sessionTitle: group.sessionTitle,
                    outbox: group.outbox,
                    artifact: $0
                )
            }
        }
        let leading = ordered.flatMap { entries($0, $0.artifacts.prefix(1)) }
        let remaining = ordered.flatMap { entries($0, $0.artifacts.dropFirst()) }
        return Array((leading + remaining).prefix(limit))
    }
}
