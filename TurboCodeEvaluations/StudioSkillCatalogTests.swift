import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Studio bundled skills")
struct StudioSkillCatalogTests {
    @Test("Studio sessions are offered the web design skill, Coding sessions are not")
    func skillIsScopedToStudio() throws {
        let studio = StudioSkillCatalog.skills(for: .cowork)
        let skill = try #require(studio.first { $0.name == StudioSkillCatalog.webDesignSkillName })

        #expect(studio.count == StudioSkillCatalog.resourceNames.count)
        #expect(!skill.description.isEmpty)
        #expect(skill.prompt.contains("--accent"))
        #expect(skill.prompt.contains("vm_view_image"))
        #expect(StudioSkillCatalog.skills(for: .coding).isEmpty)
    }

    @Test("Every skill stays small and self-contained")
    func skillsRespectTheirBudget() {
        let skills = StudioSkillCatalog.skills(for: .cowork)
        #expect(skills.count == StudioSkillCatalog.resourceNames.count)
        for skill in skills {
            // Loaded into sessions with as little as 32K of context: keep
            // each near 1,800 tokens. Raise this only with a measured reason.
            #expect(skill.prompt.utf8.count < 7_500, "\(skill.name)")
            // Exported files must work offline, so no base may teach the
            // model to pull anything from the network.
            #expect(!skill.prompt.contains("https://"), "\(skill.name)")
            #expect(!skill.prompt.contains("http://"), "\(skill.name)")
        }
    }

    @Test("The document and presentation skills produce a PDF and check its pages")
    func printSkillsRenderAndCheck() throws {
        let skills = StudioSkillCatalog.skills(for: .cowork)
        for name in [StudioSkillCatalog.documentsSkillName, StudioSkillCatalog.presentationsSkillName] {
            let skill = try #require(skills.first { $0.name == name })
            #expect(!skill.description.isEmpty)
            #expect(skill.prompt.contains("--print-to-pdf"))
            #expect(skill.prompt.contains("vm_view_image"))
            // Both forbid inventing content, the failure that matters most
            // in a document someone will send or present.
            #expect(skill.prompt.contains("[missing:"))
        }
    }

    @Test("The Studio prompt names the bundled skills, and only for Studio")
    func promptPointsAtTheSkill() {
        func prompt(_ cowork: CoworkPromptFacts?) -> String {
            TurboCodeSystemPromptBuilder.build(TurboCodeSystemPromptContext(
                role: .standalone,
                backend: .llamaServer,
                workspaceRoot: cowork == nil ? "/tmp/project" : "",
                agentTuning: .default,
                toolIDs: [.vmExec, .vmFile],
                toolNames: ["vm_exec", "vm_file"],
                availableSkills: [],
                workspaceInstructions: nil,
                cowork: cowork
            ))
        }
        let name = StudioSkillCatalog.webDesignSkillName
        let studio = prompt(.init(sessionDirectory: "/home/cowork/sessions/abc", sharesInputFolder: false))
        #expect(studio.contains("load the \(name) skill"))
        #expect(!prompt(nil).contains(name))
        // Every bundled skill is named, so a document or a deck written as
        // HTML does not fall through to the web skill.
        for name in StudioSkillCatalog.resourceNames {
            #expect(studio.contains(name))
            #expect(!prompt(nil).contains(name))
        }
    }

    @Test("A user skill with the same name replaces the bundled one")
    func userSkillWins() throws {
        let bundled = try #require(StudioSkillCatalog.skills(for: .cowork).first)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-skill-\(UUID().uuidString).md")
        try """
        ---
        name: \(bundled.name)
        description: "Mine."
        ---
        My own style.
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let mine = try TurboCodeSkillDefinition(contentsOf: url)

        let catalog = MCPConnectorCatalog.catalog(adding: [bundled], to: [mine])
        #expect(catalog.map(\.description) == ["Mine."])
    }
}
