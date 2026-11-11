import Foundation

/// Skills TurboCode ships for Studio sessions.
///
/// They are offered through `load_skill` like the user's own skills, and only
/// in the Studio domain: they describe work done in the VM and would be noise
/// in a Coding session. Unlike a connector skill they need no connector; the
/// session's domain alone makes them available.
nonisolated enum StudioSkillCatalog {
    /// Web house style. Small local models otherwise produce generic,
    /// unprofessional layouts; the Studio prompt tells them to load this
    /// before writing HTML.
    static let webDesignSkillName = "studio-web-design"

    static let resourceNames = [webDesignSkillName]

    /// The bundled skills for `domain`. A missing or malformed resource only
    /// removes that skill; the session itself is unaffected.
    @MainActor
    static func skills(
        for domain: SessionDomain,
        bundle: Bundle = .main
    ) -> [TurboCodeSkillDefinition] {
        guard domain == .cowork else { return [] }
        return resourceNames.compactMap { name in
            if bundle == .main, let cached = cache[name] { return cached }
            guard let url = bundle.url(forResource: name, withExtension: "md")
                    ?? bundle.url(
                        forResource: name,
                        withExtension: "md",
                        subdirectory: "StudioSkills"
                    ),
                  let skill = try? TurboCodeSkillDefinition(contentsOf: url) else {
                return nil
            }
            if bundle == .main { cache[name] = skill }
            return skill
        }
    }

    /// Bundled files never change while the app runs, and the composer asks
    /// for the catalog while the user types, so each one is parsed once.
    @MainActor private static var cache: [String: TurboCodeSkillDefinition] = [:]
}
