import Foundation
import Testing
@testable import TurboCode

@Suite("Agent diagnostics")
struct AgentDiagnosticsTests {
    @Test("Open tools are finalized when a run is cancelled")
    func openToolsAreFinalizedWhenRunIsCancelled() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var run = metric(startedAt: startedAt)

        AgentDiagnosticsRecorder.finalizeOpenTools(
            in: &run,
            outcome: .cancelled,
            finishedAt: startedAt.addingTimeInterval(2.5)
        )

        #expect(run.tools[0].outcome == .cancelled)
        #expect(run.tools[0].failureCategory == .interrupted)
        #expect(run.tools[0].durationMilliseconds == 2_500)
    }

    @Test("Open tools are marked interrupted when a run fails")
    func openToolsAreInterruptedWhenRunFails() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var run = metric(startedAt: startedAt)

        AgentDiagnosticsRecorder.finalizeOpenTools(
            in: &run,
            outcome: .failed,
            finishedAt: startedAt.addingTimeInterval(1)
        )

        #expect(run.tools[0].outcome == .interrupted)
        #expect(run.tools[0].durationMilliseconds == 1_000)
    }

    @Test("Common file errors receive actionable categories", arguments: [
        ("Error: File not found or not readable at path 'Missing.swift'", AgentFailureCategory.fileUnavailable),
        ("Error: startLine 40 is beyond the end of the file (12 lines).", .invalidRange),
        ("Error: Cannot read 'Asset.bin' as UTF-8 text.", .unsupportedContent),
        ("Error: fileName must be one file name in the workspace root.", .pathDenied),
        ("Error: Operations would not change 'README.md'.", .invalidEdit)
    ])
    func commonFileErrorsReceiveActionableCategories(
        detail: String,
        expected: AgentFailureCategory
    ) {
        #expect(AgentDiagnosticsRecorder.classifyFailure(detail) == expected)
    }

    private func metric(startedAt: Date) -> AgentRunMetric {
        AgentRunMetric(
            id: "run",
            startedAt: startedAt,
            backend: "Premium",
            mode: "Standalone",
            profileVersion: "test",
            workspaceKind: "git",
            promptCharacters: 1,
            source: "test",
            firstTokenMilliseconds: nil,
            totalMilliseconds: nil,
            generatedCharacters: 0,
            outcome: nil,
            failureCategory: nil,
            failureFingerprint: nil,
            suspectedTool: nil,
            tools: [
                ToolRunMetric(
                    id: "tool",
                    toolName: "read_file",
                    backend: "Premium",
                    startedAt: startedAt,
                    inputContentCharacters: nil,
                    inputLineCount: nil,
                    inputParagraphCount: nil,
                    durationMilliseconds: nil,
                    outputCharacters: nil,
                    outcome: nil,
                    failureCategory: nil,
                    failureFingerprint: nil
                )
            ]
        )
    }
}
