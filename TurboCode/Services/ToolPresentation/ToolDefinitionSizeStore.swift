import Foundation
import FoundationModels
import Observation

/// Remembers how many tokens each tool definition took the last time a
/// session registered it, so Profiles can show a profile's context cost
/// without building a session.
///
/// Values are estimates (`CapabilityContextEstimate.estimatedTokens`) of the
/// definition the model really receives: name, description, and argument
/// schema. A tool's size can differ by tier (compact vs enhanced); the last
/// measurement wins, which is close enough for a sizing hint. Only tool
/// names and integers are stored, never arguments or results.
@MainActor
@Observable
final class ToolDefinitionSizeStore {
    static let shared = ToolDefinitionSizeStore()

    private static let defaultsKey = "ToolDefinitionTokenEstimates"
    private let defaults: UserDefaults
    private(set) var tokensByToolName: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tokensByToolName = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Int] ?? [:]
    }

    /// Records the definitions of a freshly built session.
    func record(_ definitions: [Transcript.ToolDefinition]) {
        guard !definitions.isEmpty else { return }
        var updated = tokensByToolName
        for definition in definitions {
            updated[definition.name] = Self.tokens(for: definition)
        }
        guard updated != tokensByToolName else { return }
        tokensByToolName = updated
        defaults.set(updated, forKey: Self.defaultsKey)
    }

    nonisolated static func tokens(for definition: Transcript.ToolDefinition) -> Int {
        CapabilityContextEstimate.estimatedTokens(
            for: "\(definition.name) \(definition.description) \(definition.parameters)"
        )
    }
}
