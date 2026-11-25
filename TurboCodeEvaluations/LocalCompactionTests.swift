import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@Suite("Local Llama compaction")
struct LocalCompactionTests {
    private func call(
        _ id: String,
        _ tool: String,
        _ arguments: KeyValuePairs<String, any ConvertibleToGeneratedContent>
    ) -> Transcript.Entry {
        .toolCalls(Transcript.ToolCalls([
            Transcript.ToolCall(
                id: id,
                toolName: tool,
                arguments: GeneratedContent(properties: arguments)
            )
        ]))
    }

    private func output(_ id: String, _ tool: String, _ text: String) -> Transcript.Entry {
        .toolOutput(Transcript.ToolOutput(
            id: id,
            toolName: tool,
            segments: [.text(Transcript.TextSegment(content: text))]
        ))
    }

    @Test("A conversation within budget is rendered unchanged")
    func shortConversationIsUnchanged() {
        let blocks = [
            ChatBlock(kind: .user, text: "Fix the build"),
            ChatBlock(kind: .assistant, text: "Done.")
        ]
        #expect(
            RuntimeContextHandoff.renderKeepingFirstRequest(blocks: blocks, maximumCharacters: 8_000)
                == RuntimeContextHandoff.render(blocks: blocks)
        )
    }

    @Test("Truncation keeps the first request and the newest sections whole")
    func truncationKeepsFirstRequestAndNewestSections() {
        var blocks = [ChatBlock(kind: .user, text: "GOAL: migrate the settings page")]
        for index in 0..<40 {
            blocks.append(ChatBlock(kind: .assistant, text: "step \(index) " + String(repeating: "x", count: 200)))
        }
        blocks.append(ChatBlock(kind: .user, text: "LATEST: now run the tests"))

        let rendered = RuntimeContextHandoff.renderKeepingFirstRequest(
            blocks: blocks,
            maximumCharacters: 2_000
        )

        #expect(rendered.count <= 2_000)
        #expect(rendered.hasPrefix("USER:\nGOAL: migrate the settings page"))
        #expect(rendered.contains(RuntimeContextHandoff.compactionOmissionMarker))
        #expect(rendered.hasSuffix("USER:\nLATEST: now run the tests"))
        #expect(!rendered.contains("step 0 "))
        // Every kept assistant section is whole: cuts fall between sections.
        for section in rendered.components(separatedBy: "\n\n") where section.hasPrefix("ASSISTANT:") {
            #expect(section.hasSuffix(String(repeating: "x", count: 200)))
        }
    }

    @Test("An oversized newest section keeps its end")
    func oversizedNewestSectionKeepsItsEnd() {
        let blocks = [
            ChatBlock(kind: .user, text: "GOAL"),
            ChatBlock(kind: .assistant, text: String(repeating: "a", count: 5_000) + "END")
        ]
        let rendered = RuntimeContextHandoff.renderKeepingFirstRequest(
            blocks: blocks,
            maximumCharacters: 1_000
        )
        #expect(rendered.count <= 1_000)
        #expect(rendered.hasPrefix("USER:\nGOAL"))
        #expect(rendered.hasSuffix("END"))
    }

    @Test("Tool receipts list completed calls with short arguments and the first output line")
    func toolReceiptsListCompletedCalls() {
        let entries: [Transcript.Entry] = [
            call("1", "read_file", ["filePath": "TurboCode/App.swift"]),
            output("1", "read_file", "\nimport SwiftUI\nstruct App {}"),
            call("2", "edit_file", [
                "filePath": "TurboCode/App.swift",
                "content": String(repeating: "long patch ", count: 50)
            ]),
            output("2", "edit_file", "Applied 1 edit"),
            call("3", "bash", ["command": "swift build"])
        ]

        let section = SessionRebuildHistory.toolReceiptSection(
            from: entries,
            maximumCharacters: 2_000
        )

        #expect(section.hasPrefix("TOOLS USED (oldest first):"))
        #expect(section.contains("- read_file filePath: TurboCode/App.swift → import SwiftUI"))
        #expect(section.contains("- edit_file filePath: TurboCode/App.swift → Applied 1 edit"))
        #expect(!section.contains("long patch"))
        // The bash call has no output: it never completed.
        #expect(!section.contains("swift build"))
    }

    @Test("A short receipt budget keeps the newest calls and counts the rest")
    func shortReceiptBudgetKeepsNewestCalls() {
        var entries: [Transcript.Entry] = []
        for index in 0..<20 {
            entries.append(call("\(index)", "read_file", ["filePath": "File\(index).swift"]))
            entries.append(output("\(index)", "read_file", "ok"))
        }
        let section = SessionRebuildHistory.toolReceiptSection(from: entries, maximumCharacters: 200)

        #expect(section.count <= 200 + 40)
        #expect(section.contains("File19.swift"))
        #expect(!section.contains("File0.swift"))
        #expect(section.contains("earlier calls omitted"))
    }

    @Test("Compaction summary carries receipts and the first request")
    func compactionSummaryCarriesReceiptsAndFirstRequest() throws {
        let compaction = try #require(
            SessionRebuildHistory.localCompaction(
                from: [
                    ChatBlock(kind: .user, text: "GOAL: add autocompact"),
                    ChatBlock(kind: .assistant, text: "Implemented.")
                ],
                toolEntries: [
                    call("1", "read_file", ["filePath": "ChatStore.swift"]),
                    output("1", "read_file", "import Foundation")
                ],
                maximumCharacters: 8_000
            )
        )
        #expect(compaction.summary.contains("- read_file filePath: ChatStore.swift"))
        #expect(compaction.summary.contains("GOAL: add autocompact"))
        #expect(compaction.summary.contains("CONVERSATION:"))
        #expect(compaction.retainedCharacters <= 8_000)
    }
}

@Suite("Local Llama automatic compaction")
struct LocalAutoCompactionTests {
    @Test("Compaction triggers at the threshold for llama-server only")
    func triggersAtThresholdForLlamaServerOnly() {
        let atThreshold = LlamaContextUsage(usedTokens: 8_000, contextSize: 10_000)
        let below = LlamaContextUsage(usedTokens: 7_999, contextSize: 10_000)

        #expect(SessionRebuildHistory.shouldAutoCompact(
            backend: .llamaServer, usage: atThreshold, thresholdPercent: 80))
        #expect(!SessionRebuildHistory.shouldAutoCompact(
            backend: .llamaServer, usage: below, thresholdPercent: 80))
        // Unknown fill: no llama-server /props, or a rebuild cleared it.
        #expect(!SessionRebuildHistory.shouldAutoCompact(
            backend: .llamaServer, usage: nil, thresholdPercent: 80))
        #expect(!SessionRebuildHistory.shouldAutoCompact(
            backend: .llamaServer, usage: atThreshold, thresholdPercent: 0))
        #expect(!SessionRebuildHistory.shouldAutoCompact(
            backend: .foundationApple, usage: atThreshold, thresholdPercent: 80))
    }

    @Test("The threshold defaults to 80 percent and rejects values outside the range")
    func thresholdDefaultsAndValidation() throws {
        let decoded = try JSONDecoder().decode(
            AgentTuningConfig.self,
            from: Data(#"{"agent":{"responseStyle":"balanced"}}"#.utf8)
        )
        #expect(decoded.agent.autoCompactThresholdPercent == 80)

        var off = AgentTuningConfig()
        off.agent.autoCompactThresholdPercent = 0
        #expect(try off.validated().agent.autoCompactThresholdPercent == 0)

        var invalid = AgentTuningConfig()
        invalid.agent.autoCompactThresholdPercent = 30
        #expect(throws: AgentTuningError.self) { try invalid.validated() }
    }
}
