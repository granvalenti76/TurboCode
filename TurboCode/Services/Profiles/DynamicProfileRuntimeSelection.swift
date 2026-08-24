import Foundation

/// Resolves disk skills at the same capability boundary as dynamic tools.
/// Built-in profiles suppress only TurboCode's oversized product guide; user
/// skills remain available, while custom profiles can explicitly re-enable it.
nonisolated enum DynamicProfileRuntimeSelection {
    /// The built-in product guide is opt-in because it duplicates core runtime
    /// context and is too large for the default model prefix.
    static let builtInSuppressedSkillName = "turbocode"

    /// Reserved built-in skill name for the opt-in Safari MCP integration.
    /// Keeping the filter here prevents disabled experimental content from
    /// entering any Foundation Models profile, including Codex handoffs.
    static let safariMCPSkillName = "safari-mcp"

    static func skills(
        from available: [TurboCodeSkillDefinition],
        profile: UserDynamicProfile?,
        safariMCPEnabled: Bool = false
    ) -> [TurboCodeSkillDefinition] {
        // Filesystem discovery order is not a runtime contract. Canonicalizing
        // it keeps both the instructions catalog and load_skill schema stable,
        // allowing provider prefix caches (notably DeepSeek's) to be reused.
        let canonical = available.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let experimentalFiltered = safariMCPEnabled
            ? canonical
            : canonical.filter { $0.name != safariMCPSkillName }
        guard let profile else {
            return experimentalFiltered.filter {
                $0.name != builtInSuppressedSkillName
            }
        }
        let allowed = Set(profile.skillIDs)
        return experimentalFiltered.filter { allowed.contains($0.name) }
    }
}
