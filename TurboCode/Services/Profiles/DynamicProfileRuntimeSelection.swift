import Foundation

/// Resolves the discovered Markdown skill catalog at the profile boundary.
/// Built-in profiles receive every discovered skill; custom profiles are the
/// only boundary allowed to narrow the catalog through their explicit IDs.
nonisolated enum DynamicProfileRuntimeSelection {
    static func skills(
        from available: [TurboCodeSkillDefinition],
        profile: UserDynamicProfile?
    ) -> [TurboCodeSkillDefinition] {
        // Filesystem discovery order is not a runtime contract. Canonicalizing
        // it keeps both the instructions catalog and load_skill schema stable,
        // allowing provider prefix caches (notably DeepSeek's) to be reused.
        let canonical = available.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard let profile else {
            return canonical
        }
        let allowed = Set(profile.skillIDs)
        return canonical.filter { allowed.contains($0.name) }
    }
}
