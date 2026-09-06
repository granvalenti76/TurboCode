import Foundation
import FoundationModels

/// Response-scoped diagnostics boundary shared by native and Codex execution.
///
/// Capture remains synchronous on MainActor so UI apply timing is precise;
/// persistence is forwarded in batches to `AgentDiagnosticsRecorder` after the
/// provider settles.
@MainActor
final class ResponseDiagnostics {
    @MainActor
    final class Capture {
        struct CompletedTool {
            let call: ToolCall
            let result: ToolResult
        }

        let runID: String?
        private(set) var firstTokenAt: Date?
        private(set) var generatedCharacters = 0
        private(set) var publicationCount = 0
        private(set) var publicationDurationMilliseconds = 0
        private(set) var startedTools: [ToolCall] = []
        private(set) var completedTools: [CompletedTool] = []

        init(runID: String? = nil) {
            self.runID = runID
        }

        func recordPublication(apply: () -> Void) {
            measureApply(apply)
            publicationCount += 1
        }

        func recordCodexText(_ text: String, apply: () -> Void) {
            guard !text.isEmpty else { return }
            measureApply(apply)
            publicationCount += 1
            firstTokenAt = firstTokenAt ?? Date()
            generatedCharacters = max(generatedCharacters, text.count)
        }

        func toolStarted(_ call: ToolCall) {
            startedTools.append(call)
        }

        func toolFinished(_ result: ToolResult) {
            guard let call = startedTools.last(where: { $0.id == result.id }) else {
                return
            }
            completedTools.append(CompletedTool(call: call, result: result))
        }

        private func measureApply(_ apply: () -> Void) {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            apply()
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            publicationDurationMilliseconds += Int(elapsed / 1_000_000)
        }
    }

    private var activeRunID: String?

    func beginCodexRun(
        mode: OrchestratorMode,
        workspaceKind: String,
        promptCharacters: Int
    ) async -> Capture {
        let runID = await AgentDiagnosticsRecorder.shared.startRun(
            backend: .codex,
            mode: mode,
            profileVersion: AgentProfileVersion.value(
                for: .codex,
                mode: mode
            ),
            workspaceKind: workspaceKind,
            promptCharacters: promptCharacters
        )
        activeRunID = runID
        return Capture(runID: runID)
    }

    func makePublicationCapture() -> Capture {
        Capture()
    }

    func activateRun(_ runID: String?) {
        activeRunID = runID
    }

    func toolStarted(
        _ call: Transcript.ToolCall,
        backend: ModelBackend
    ) async {
        guard let activeRunID else { return }
        await AgentDiagnosticsRecorder.shared.toolStarted(
            runID: activeRunID,
            call: call,
            backend: backend
        )
    }

    func toolFinished(
        _ call: Transcript.ToolCall,
        output: Transcript.ToolOutput,
        backend: ModelBackend
    ) async {
        guard let activeRunID else { return }
        await AgentDiagnosticsRecorder.shared.toolFinished(
            runID: activeRunID,
            call: call,
            output: output,
            backend: backend
        )
    }

    func finishCodex(
        capture: Capture,
        outcome: TurnOutcome
    ) async {
        guard let runID = capture.runID else { return }
        if let firstTokenAt = capture.firstTokenAt {
            await AgentDiagnosticsRecorder.shared.markFirstToken(
                runID: runID,
                at: firstTokenAt
            )
        }
        for call in capture.startedTools {
            await AgentDiagnosticsRecorder.shared.toolStarted(
                runID: runID,
                call: call,
                backend: .codex
            )
        }
        for completion in capture.completedTools {
            await AgentDiagnosticsRecorder.shared.toolFinished(
                runID: runID,
                call: completion.call,
                output: completion.result,
                backend: .codex
            )
        }

        let diagnosticOutcome: AgentRunOutcome
        let failure: TurnFailure?
        switch outcome {
        case .succeeded:
            diagnosticOutcome = .success
            failure = nil
        case .cancelled:
            diagnosticOutcome = .cancelled
            failure = nil
        case .failed(let turnFailure):
            diagnosticOutcome = .failed
            failure = turnFailure
        }
        await AgentDiagnosticsRecorder.shared.finishRun(
            runID: runID,
            outcome: diagnosticOutcome,
            generatedCharacters: capture.generatedCharacters,
            failure: failure
        )
        if activeRunID == runID {
            activeRunID = nil
        }
    }

    func recordBoundaries(
        backend: ModelBackend,
        settlementStartedAt: Date,
        capture: Capture
    ) async {
        let settlementDuration = max(
            0,
            Int(Date().timeIntervalSince(settlementStartedAt) * 1_000)
        )
        await AgentDiagnosticsRecorder.shared.recordBoundary(
            RuntimeBoundaryMetric(
                boundary: .settlement,
                backend: backend.rawValue,
                durationMilliseconds: settlementDuration
            )
        )
        await AgentDiagnosticsRecorder.shared.recordBoundary(
            RuntimeBoundaryMetric(
                boundary: .mainActorPublication,
                backend: backend.rawValue,
                durationMilliseconds:
                    capture.publicationDurationMilliseconds,
                eventCount: capture.publicationCount
            )
        )
    }
}
