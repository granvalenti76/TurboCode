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

    /// The skills `load_skill` offers in a Studio session, before connector
    /// skills are added.
    ///
    /// Bundled Studio skills are locked on: the Studio prompt tells the model
    /// to load them, so a profile cannot remove them. A user skill with a
    /// bundled name overrides that skill and is locked on the same way.
    /// The profile's Studio selection only chooses among the other user
    /// skills; without one, the Coding selection decides, as before.
    static func studioSkills(
        from available: [TurboCodeSkillDefinition],
        bundled: [TurboCodeSkillDefinition],
        profile: UserDynamicProfile?
    ) -> [TurboCodeSkillDefinition] {
        let lockedNames = Set(bundled.map(\.name))
        let allowed: Set<String>
        if let selection = profile?.studioSkillIDs {
            allowed = Set(selection)
        } else {
            allowed = Set(skills(from: available, profile: profile).map(\.name))
        }
        let users = skills(from: available, profile: nil)
            .filter { lockedNames.contains($0.name) || allowed.contains($0.name) }
        return merging(bundled, into: users)
    }

    /// Names a Studio profile cannot remove: the bundled Studio skills.
    static func lockedStudioSkillNames(bundled: [TurboCodeSkillDefinition]) -> Set<String> {
        Set(bundled.map(\.name))
    }

    /// Appends bundled skills a user skill of the same name does not
    /// override. Same rule as `MCPConnectorCatalog.catalog`, kept here
    /// because that one is main-actor isolated and this type is not.
    private static func merging(
        _ bundled: [TurboCodeSkillDefinition],
        into skills: [TurboCodeSkillDefinition]
    ) -> [TurboCodeSkillDefinition] {
        skills + bundled.filter { added in !skills.contains { $0.name == added.name } }
    }
}
