import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Model switching")
struct ModelSwitchRegressionTests {
    @Test("A capability change keeps conversation turns and removes model-specific context")
    func capabilityChangeSanitizesTranscript() {
        let entries = fixtureTranscript()

        let result = SessionRebuildHistory.prepare(
            Transcript(entries: entries),
            keepingHistory: true,
            discardingCapabilityContext: true
        )

        #expect(result.count == 2)
        #expect(result.contains { if case .prompt = $0 { true } else { false } })
        #expect(result.contains { if case .response = $0 { true } else { false } })
        #expect(!result.contains { if case .instructions = $0 { true } else { false } })
        #expect(!result.contains { if case .toolCalls = $0 { true } else { false } })
        #expect(!result.contains { if case .toolOutput = $0 { true } else { false } })
        #expect(!result.contains { if case .reasoning = $0 { true } else { false } })
    }

    @Test("A same-model rebuild preserves transport context but replaces instructions")
    func sameModelRebuildPreservesTransportEntries() {
        let entries = fixtureTranscript()

        let result = SessionRebuildHistory.prepare(
            Transcript(entries: entries),
            keepingHistory: true,
            discardingCapabilityContext: false
        )

        #expect(result.count == entries.count - 1)
        #expect(!result.contains { if case .instructions = $0 { true } else { false } })
        #expect(result.contains { if case .toolCalls = $0 { true } else { false } })
        #expect(result.contains { if case .toolOutput = $0 { true } else { false } })
        #expect(result.contains { if case .reasoning = $0 { true } else { false } })
    }

    @Test("A dynamic profile receives only its selected disk skills")
    func dynamicProfileFiltersSkills() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-ModelSwitch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try makeSkill(name: "pr-review", root: root)
        let excluded = try makeSkill(name: "release-notes", root: root)
        let profile = UserDynamicProfile(
            name: "PR only",
            baseModelID: .pcc,
            toolIDs: [ToolCapabilityID.git.rawValue],
            skillIDs: [selected.name]
        )

        let resolved = DynamicProfileRuntimeSelection.skills(
            from: [selected, excluded],
            profile: profile
        )

        #expect(resolved.map(\.name) == ["pr-review"])
        #expect(profile.resolvedToolIDs == [.git, .loadSkill])
    }

    private func fixtureTranscript() -> [Transcript.Entry] {
        let text: (String) -> Transcript.Segment = {
            .text(Transcript.TextSegment(content: $0))
        }
        let call = Transcript.ToolCall(
            id: "call-1",
            toolName: "git",
            arguments: GeneratedContent(properties: ["operation": "status"])
        )
        return [
            .instructions(Transcript.Instructions(segments: [text("old")], toolDefinitions: [])),
            .prompt(Transcript.Prompt(segments: [text("Inspect the repository")])),
            .reasoning(Transcript.Reasoning(segments: [text("private transport state")])),
            .toolCalls(Transcript.ToolCalls([call])),
            .toolOutput(Transcript.ToolOutput(
                id: "call-1",
                toolName: "git",
                segments: [text("clean")]
            )),
            .response(Transcript.Response(assetIDs: [], segments: [text("The repository is clean.")]))
        ]
    }

    private func makeSkill(name: String, root: URL) throws -> TurboCodeSkillDefinition {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("SKILL.md")
        try """
        ---
        name: \(name)
        description: Test \(name)
        ---
        Follow only the selected workflow.
        """.write(to: url, atomically: true, encoding: .utf8)
        return try TurboCodeSkillDefinition(contentsOf: url)
    }
}
