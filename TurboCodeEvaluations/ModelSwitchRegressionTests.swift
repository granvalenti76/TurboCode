import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Model switching")
struct ModelSwitchRegressionTests {
    @Test("Interrupted turn repair restores a transcript omitted by cancellation")
    func interruptedTurnRepairAddsMissingSemanticEntries() throws {
        let text: (String) -> Transcript.Segment = {
            .text(Transcript.TextSegment(content: $0))
        }
        let textContent: ([Transcript.Segment]) -> String = { segments in
            segments.compactMap { segment in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }
        let baseline: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [text("Earlier request")])),
            .response(Transcript.Response(
                assetIDs: [],
                segments: [text("Earlier response")]
            ))
        ]

        let repaired = SessionRebuildHistory.reconcilingInterruptedTurn(
            baseline: baseline,
            current: baseline,
            prompt: "Interrupted request",
            reasoning: "Partial reasoning",
            response: "Partial response"
        )

        #expect(repaired.count == 5)
        guard case .prompt(let prompt) = repaired[2],
              case .reasoning(let reasoning) = repaired[3],
              case .response(let response) = repaired[4] else {
            Issue.record("Interrupted semantic entries were not restored in order")
            return
        }
        #expect(textContent(prompt.segments) == "Interrupted request")
        #expect(textContent(reasoning.segments) == "Partial reasoning")
        #expect(textContent(response.segments) == "Partial response")
    }

    @Test("Interrupted turn repair retains provider entries without duplication")
    func interruptedTurnRepairKeepsExistingProviderDelta() {
        let text: (String) -> Transcript.Segment = {
            .text(Transcript.TextSegment(content: $0))
        }
        let baseline: [Transcript.Entry] = [
            .prompt(Transcript.Prompt(segments: [text("Earlier request")]))
        ]
        let current = baseline + [
            Transcript.Entry.prompt(
                Transcript.Prompt(segments: [text("Interrupted request")])
            ),
            .reasoning(
                Transcript.Reasoning(segments: [text("Recorded reasoning")])
            ),
            .response(
                Transcript.Response(
                    assetIDs: [],
                    segments: [text("Recorded response")]
                )
            )
        ]

        let repaired = SessionRebuildHistory.reconcilingInterruptedTurn(
            baseline: baseline,
            current: current,
            prompt: "Interrupted request",
            reasoning: "Duplicate reasoning",
            response: "Duplicate response"
        )

        #expect(repaired.count == current.count)
    }

    @Test("Llama profiles retain completed tool calls for cache-stable history")
    func llamaProfilesKeepAppendOnlyHistory() {
        // Built-in and custom Llama profiles both resolve to llamaServer, so the
        // backend policy covers overrides without depending on editable metadata.
        #expect(!ModelHistoryPolicy.dropsCompletedToolCalls(
            backend: .llamaServer,
            reasoningTransport: .contextOptions
        ))

        // Preserve the established policies for compact Apple/PCC history and
        // DeepSeek's complete provider-specific reasoning transcript.
        #expect(ModelHistoryPolicy.dropsCompletedToolCalls(
            backend: .foundationApple,
            reasoningTransport: nil
        ))
        #expect(ModelHistoryPolicy.dropsCompletedToolCalls(
            backend: .foundationServe,
            reasoningTransport: .none
        ))
        #expect(!ModelHistoryPolicy.dropsCompletedToolCalls(
            backend: .premium,
            reasoningTransport: .deepseekThinking
        ))
    }

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

    @Test("A persisted transcript round-trips complete tool exchanges")
    func persistedTranscriptRoundTrips() throws {
        let transcript = Transcript(entries: fixtureTranscript())
        let stored = StoredSession(
            title: "Persisted chat",
            projectName: "TurboCode",
            transcript: transcript
        )

        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredSession.self, from: data)
        let restored = try #require(decoded.transcript)

        #expect(restored.count == transcript.count)
        #expect(restored.contains { entry in
            guard case .toolCalls(let calls) = entry else { return false }
            return calls.contains { $0.id == "call-1" && $0.toolName == "git" }
        })
        #expect(restored.contains { entry in
            guard case .toolOutput(let output) = entry else { return false }
            return output.id == "call-1" && output.toolName == "git"
        })
        #expect(restored.contains { if case .reasoning = $0 { true } else { false } })
        #expect(restored.contains { if case .response = $0 { true } else { false } })
    }

    @Test("Conversation metadata round-trips and legacy sessions receive safe defaults")
    func conversationMetadataRoundTripsAndMigrates() throws {
        let stored = StoredSession(
            title: "Pinned plan",
            projectName: "TurboCode",
            isPinned: true,
            isArchived: true,
            mode: .plan
        )
        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredSession.self, from: data)

        #expect(decoded.schemaVersion == StoredSession.currentSchemaVersion)
        #expect(decoded.isPinned)
        #expect(decoded.isArchived)
        #expect(decoded.mode == .plan)

        var legacy = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        legacy.removeValue(forKey: "schemaVersion")
        legacy.removeValue(forKey: "isPinned")
        legacy.removeValue(forKey: "isArchived")
        legacy.removeValue(forKey: "mode")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let migrated = try JSONDecoder().decode(StoredSession.self, from: legacyData)

        #expect(migrated.schemaVersion == StoredSession.currentSchemaVersion)
        #expect(!migrated.isPinned)
        #expect(!migrated.isArchived)
        #expect(migrated.mode == .agent)
    }

    @Test("Legacy visible blocks recover user and assistant turns")
    func legacyBlocksRecoverConversationTurns() {
        let result = SessionRebuildHistory.fromVisibleBlocks([
            ChatBlock(kind: .user, text: "Inspect the repository"),
            ChatBlock(kind: .reasoning, text: "Internal reasoning"),
            ChatBlock(kind: .tool, text: "git status"),
            ChatBlock(kind: .assistant, text: "The repository is clean.")
        ])

        #expect(result.count == 2)
        #expect(result.contains { if case .prompt = $0 { true } else { false } })
        #expect(result.contains { if case .response = $0 { true } else { false } })
        #expect(!result.contains { if case .reasoning = $0 { true } else { false } })
        #expect(!result.contains { if case .toolCalls = $0 { true } else { false } })
        #expect(!result.contains { if case .toolOutput = $0 { true } else { false } })
    }

    @Test("On-device compaction keeps durable outcomes and drops tool chatter")
    func onDeviceCompactionKeepsEssentialContext() throws {
        let transcript = Transcript(entries: fixtureTranscript())
        #expect(SessionRebuildHistory.userTurnCount(in: transcript) == 1)

        let compaction = try #require(
            SessionRebuildHistory.onDeviceCompaction(from: [
                ChatBlock(kind: .user, text: "Inspect the repository"),
                ChatBlock(kind: .tool, text: "raw tool output: secret noise"),
                ChatBlock(kind: .assistant, text: "The repository is clean.")
            ])
        )

        #expect(compaction.summary.contains("The repository is clean."))
        #expect(!compaction.summary.contains("secret noise"))
        #expect(compaction.history.count == 2)
        #expect(
            SessionRebuildHistory.userTurnCount(
                in: Transcript(entries: compaction.history)
            ) == 0
        )
        #expect(
            compaction.history.contains {
                if case .response = $0 { return true }
                return false
            }
        )
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

    @Test("Runtime skills have a stable cache-friendly order")
    func runtimeSkillsAreCanonicalized() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-SkillOrder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zebra = try makeSkill(name: "zebra", root: root)
        let alpha = try makeSkill(name: "alpha", root: root)

        let resolved = DynamicProfileRuntimeSelection.skills(
            from: [zebra, alpha],
            profile: nil
        )

        #expect(resolved.map(\.name) == ["alpha", "zebra"])
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

    @Test("Local Llama compaction preserves outcomes and reports adaptive sizes")
    func localCompactionKeepsEssentialContext() throws {
        #expect(SessionRebuildHistory.localCompactionCharacterLimit(contextWindowTokens: 32_768) == 12_288)
        #expect(SessionRebuildHistory.localCompactionCharacterLimit(contextWindowTokens: 128_000) == 48_000)
        #expect(SessionRebuildHistory.localCompactionCharacterLimit(contextWindowTokens: 256_000) == 96_000)
        #expect(SessionRebuildHistory.localCompactionCharacterLimit(contextWindowTokens: nil) == 12_288)

        let compaction = try #require(
            SessionRebuildHistory.localCompaction(
                from: [
                    ChatBlock(kind: .user, text: "Inspect the repository"),
                    ChatBlock(kind: .tool, text: "raw tool output: secret noise"),
                    ChatBlock(kind: .assistant, text: "The repository is clean.")
                ],
                maximumCharacters: 8_000
            )
        )

        #expect(compaction.summary.contains("local Llama"))
        #expect(compaction.summary.contains("The repository is clean."))
        #expect(!compaction.summary.contains("secret noise"))
        #expect(compaction.sourceCharacters > compaction.retainedCharacters)
        #expect(compaction.history.count == 2)
    }
}
