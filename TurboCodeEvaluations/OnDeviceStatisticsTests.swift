import Foundation
import Testing
@testable import TurboCode

@Suite("On-device statistics")
struct OnDeviceStatisticsTests {
    @Test("Summary measures generation and excludes delegated tool calls")
    func summaryFiltersDelegateMetrics() {
        let run = makeRun(
            inputTokens: 100,
            cachedTokens: 60,
            outputTokens: 40,
            tools: [
                makeTool(name: "read_file", backend: .foundationApple, outcome: .failed),
                makeTool(name: "bash", backend: .premium, outcome: .failed)
            ]
        )

        let summary = OnDeviceStatisticsSummary(runs: [run])

        #expect(summary.requestCount == 1)
        #expect(summary.toolCalls.map(\.toolName) == ["read_file"])
        #expect(summary.errors.map(\.source) == ["read_file"])
        #expect(summary.tokensPerSecond == 20)
        #expect(summary.cacheHitRate == 0.6)
        #expect(summary.latestContext?.used == 6_000)
        #expect(summary.latestContext?.size == 8_192)
    }

    /// Fixtures spell out every persisted field so additions to the diagnostic
    /// schema remain deliberate and visible to this compatibility test.
    private func makeRun(
        inputTokens: Int,
        cachedTokens: Int,
        outputTokens: Int,
        tools: [ToolRunMetric]
    ) -> AgentRunMetric {
        AgentRunMetric(
            id: "run",
            startedAt: Date(timeIntervalSince1970: 1_000),
            backend: ModelBackend.foundationApple.rawValue,
            mode: OrchestratorMode.standalone.rawValue,
            profileVersion: "test",
            workspaceKind: "git",
            promptCharacters: 20,
            source: "interactive",
            firstTokenMilliseconds: 1_000,
            totalMilliseconds: 3_000,
            generatedCharacters: 100,
            outcome: .successWithToolFailures,
            failureCategory: nil,
            failureFingerprint: nil,
            suspectedTool: nil,
            tools: tools,
            inputTokenCount: inputTokens,
            cachedInputTokenCount: cachedTokens,
            outputTokenCount: outputTokens,
            contextTokenCount: 6_000,
            contextSize: 8_192
        )
    }

    private func makeTool(
        name: String,
        backend: ModelBackend,
        outcome: ToolRunOutcome
    ) -> ToolRunMetric {
        ToolRunMetric(
            id: "\(backend.rawValue)-\(name)",
            toolName: name,
            backend: backend.rawValue,
            startedAt: Date(timeIntervalSince1970: 1_001),
            inputContentCharacters: nil,
            inputLineCount: nil,
            inputParagraphCount: nil,
            durationMilliseconds: 100,
            outputCharacters: 20,
            outcome: outcome,
            failureCategory: outcome == .failed ? .toolExecution : nil,
            failureFingerprint: outcome == .failed ? "fingerprint" : nil
        )
    }
}
