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

    @Test("Runtime boundary metrics clamp baseline values")
    func runtimeBoundaryMetricsClampBaselineValues() {
        let metric = RuntimeBoundaryMetric(
            boundary: .restore,
            backend: "foundationApple",
            durationMilliseconds: -10,
            eventCount: -2
        )

        #expect(metric.durationMilliseconds == 0)
        #expect(metric.eventCount == 0)
    }

    @Test("Runtime baseline aggregates runs and boundary samples")
    func runtimeBaselineAggregatesSamples() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let run = AgentRunMetric(
            id: "run",
            startedAt: startedAt,
            backend: "Foundation Apple",
            mode: "Standalone",
            profileVersion: "test",
            workspaceKind: "git",
            promptCharacters: 10,
            source: "test",
            firstTokenMilliseconds: 120,
            totalMilliseconds: 900,
            generatedCharacters: 20,
            outcome: .success,
            failureCategory: nil,
            failureFingerprint: nil,
            suspectedTool: nil,
            tools: [
                ToolRunMetric(
                    id: "tool",
                    toolName: "read_file",
                    backend: "Foundation Apple",
                    startedAt: startedAt,
                    inputContentCharacters: nil,
                    inputLineCount: nil,
                    inputParagraphCount: nil,
                    durationMilliseconds: 40,
                    outputCharacters: nil,
                    outcome: .success,
                    failureCategory: nil,
                    failureFingerprint: nil
                )
            ],
            inputTokenCount: 80,
            cachedInputTokenCount: 20,
            outputTokenCount: 30,
            contextTokenCount: 50,
            contextSize: 100
        )
        let boundaries = [
            RuntimeBoundaryMetric(
                boundary: .settlement,
                durationMilliseconds: 12
            ),
            RuntimeBoundaryMetric(
                boundary: .persistence,
                durationMilliseconds: 8
            ),
            RuntimeBoundaryMetric(
                boundary: .restore,
                durationMilliseconds: 16
            ),
            RuntimeBoundaryMetric(
                boundary: .mainActorPublication,
                durationMilliseconds: 3,
                eventCount: 5
            )
        ]

        let summary = RuntimeBaselineSummary(runs: [run], boundaries: boundaries)

        #expect(summary.runCount == 1)
        #expect(summary.averageFirstTokenMilliseconds == 120)
        #expect(summary.averageProviderMilliseconds == 900)
        #expect(summary.averageContextOccupancyPercent == 50)
        #expect(summary.averageToolMilliseconds == 40)
        #expect(summary.averageSettlementMilliseconds == 12)
        #expect(summary.averagePersistenceMilliseconds == 8)
        #expect(summary.averageRestoreMilliseconds == 16)
        #expect(summary.averagePublicationCount == 5)
        #expect(summary.averagePublicationDurationMilliseconds == 3)
    }

    @Test("Response diagnostics capture publications and matched Codex tools")
    @MainActor
    func responseDiagnosticsCapturePreservesBatchInputs() {
        let capture = ResponseDiagnostics.Capture()
        var appliedTexts: [String] = []

        capture.recordCodexText("") {
            appliedTexts.append("empty")
        }
        capture.recordCodexText("response") {
            appliedTexts.append("response")
        }
        capture.recordPublication {
            appliedTexts.append("native")
        }

        let turnID = TurnID(rawValue: "diagnostics-capture")
        capture.toolStarted(
            ToolCall(id: "tool", turnID: turnID, name: "read_file")
        )
        capture.toolFinished(
            ToolResult(
                id: "tool",
                turnID: turnID,
                status: .succeeded,
                output: "ok"
            )
        )

        #expect(appliedTexts == ["response", "native"])
        #expect(capture.publicationCount == 2)
        #expect(capture.generatedCharacters == 8)
        #expect(capture.firstTokenAt != nil)
        #expect(capture.startedTools.count == 1)
        #expect(capture.completedTools.count == 1)
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
