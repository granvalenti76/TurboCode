import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Skill editor persistence")
struct TurboCodeSkillEditorTests {
    @Test("Round-trips model profiles and unmanaged front matter")
    func roundTripsProfiles() throws {
        let source = """
        ---
        name: "review-pr"
        description: "Review a pull request"
        author: "TurboCode user"
        profiles:
          on-device:
            inherit-defaults: false
            tools:
              - "write_ondevice"
          pcc:
            inherit-defaults: true
            tools:
              - "git_status"
        ---
        # Pull Request Review

        Inspect the change before commenting.
        """
        let originalURL = URL(fileURLWithPath: "/tmp/review-pr/SKILL.md")
        let definition = try TurboCodeSkillDefinition(source: source, sourceURL: originalURL)

        #expect(definition.profileOverrides["on-device"]?.inheritsDefaults == false)
        #expect(definition.profileOverrides["on-device"]?.toolIDs == ["write_ondevice"])
        #expect(definition.unmanagedFrontMatterLines.contains("author: \"TurboCode user\""))

        let rendered = try TurboCodeSkillDefinition.render(
            name: definition.name,
            description: definition.description,
            prompt: definition.prompt,
            profileOverrides: definition.profileOverrides,
            unmanagedFrontMatterLines: definition.unmanagedFrontMatterLines
        )
        let reparsed = try TurboCodeSkillDefinition(source: rendered, sourceURL: originalURL)

        #expect(reparsed.profileOverrides == definition.profileOverrides)
        #expect(reparsed.prompt == definition.prompt)
        #expect(rendered.contains("author: \"TurboCode user\""))
    }

    @Test("Renames a skill without losing companion files")
    func renamePreservesCompanionFiles() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SkillEditingService(rootURL: root)
        let saved = try service.save(SkillDraft(suggestedName: "review-pr"))
        let companion = saved.sourceURL.deletingLastPathComponent().appendingPathComponent("REFERENCE.md")
        try "Keep me".write(to: companion, atomically: true, encoding: .utf8)

        var draft = SkillDraft(definition: saved, builtInNames: [])
        draft.name = "review-pull-request"
        let renamed = try service.save(draft)

        #expect(renamed.sourceURL.deletingLastPathComponent().lastPathComponent == "review-pull-request")
        #expect(try String(
            contentsOf: renamed.sourceURL.deletingLastPathComponent().appendingPathComponent("REFERENCE.md"),
            encoding: .utf8
        ) == "Keep me")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("review-pr").path))
    }

    @Test("Rejects a duplicate directory when creating a skill")
    func rejectsDuplicateSkill() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SkillEditingService(rootURL: root)
        _ = try service.save(SkillDraft(suggestedName: "review-pr"))

        #expect(throws: TurboCodeSkillError.self) {
            _ = try service.save(SkillDraft(suggestedName: "review-pr"))
        }
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-SkillEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
