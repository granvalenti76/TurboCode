import Foundation

/// Presentation metadata attached to an assistant response that was grounded in
/// TurboCode's official product documentation.
nonisolated public struct ProductGuideBlock: Codable, Hashable, Sendable {
    public let title: String
    public let documentationVersion: String
    public let sources: [ProductGuideSource]
    public let actions: [ProductGuideAction]

    public init(
        title: String,
        documentationVersion: String,
        sources: [ProductGuideSource],
        actions: [ProductGuideAction]
    ) {
        self.title = title
        self.documentationVersion = documentationVersion
        self.sources = sources
        self.actions = actions
    }

    init?(toolOutput: String) {
        let startMarker = "<turbocode-guide-presentation>"
        let endMarker = "</turbocode-guide-presentation>"
        guard let start = toolOutput.range(of: startMarker),
              let end = toolOutput.range(of: endMarker, range: start.upperBound..<toolOutput.endIndex),
              let data = String(toolOutput[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

nonisolated public struct ProductGuideSource: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
}

nonisolated public enum ProductGuideAction: String, Codable, Hashable, Sendable {
    case chooseWorkspace
    case openSettings
}
