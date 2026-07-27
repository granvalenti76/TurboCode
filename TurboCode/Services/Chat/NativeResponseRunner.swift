import Foundation
import FoundationModels
import FoundationModelsUtilities

/// Runs one FoundationModels turn and reports domain-neutral streaming state.
///
/// The runner owns provider streaming and diagnostics only. It deliberately
/// does not know about conversations, timeline blocks, workspace mutations, or
/// navigation; ChatStore decides how the returned outcome is presented.
@MainActor
final class NativeResponseRunner {
    struct Request {
        let prompt: String
        let backend: ModelBackend
        let mode: OrchestratorMode
        let workspaceKind: String
    }

    enum Outcome {
        case completed(content: String, reasoning: String)
        case repetitiveOutput(partialContent: String, reasoning: String)
        case cancelled(partialContent: String, reasoning: String)
        case failed(message: String, partialContent: String, reasoning: String)
    }

    struct Events {
        let diagnosticsChanged: (String?) -> Void
        let liveContentChanged: (String) -> Void
        let liveReasoningChanged: (String) -> Void
        let approvalRequested: (ApprovalRequest) -> Void
    }

    func run(
        session: LanguageModelSession,
        request: Request,
        events: Events
    ) async -> Outcome {
        let runID = await AgentDiagnosticsRecorder.shared.startRun(
            backend: request.backend,
            mode: request.mode,
            profileVersion: AgentProfileVersion.value(
                for: request.backend,
                mode: request.mode
            ),
            workspaceKind: request.workspaceKind,
            promptCharacters: request.prompt.count
        )
        events.diagnosticsChanged(runID)

        var outcome: AgentRunOutcome = .success
        var recordedError: Error?
        var generatedCharacters = 0
        var didRecordFirstToken = false
        var content = ""
        var reasoning = ""
        var result: Outcome

        do {
            for try await snapshot in session.streamResponse(to: request.prompt) {
                try Task.checkCancellation()

                if request.backend == .foundationApple, let runID {
                    await AgentDiagnosticsRecorder.shared.recordUsage(
                        runID: runID,
                        usage: snapshot.usage
                    )
                }

                if !snapshot.content.isEmpty {
                    if !didRecordFirstToken, let runID {
                        didRecordFirstToken = true
                        await AgentDiagnosticsRecorder.shared.markFirstToken(
                            runID: runID
                        )
                    }
                    content = snapshot.content
                    if request.backend == .foundationApple,
                       OnDeviceStreamingGuard.isPathological(content) {
                        throw OnDeviceStreamingGuard.Failure.repetitiveOutput
                    }
                    generatedCharacters = max(generatedCharacters, content.count)
                    events.liveContentChanged(content)
                }

                for entry in snapshot.transcriptEntries {
                    switch entry {
                    case .reasoning(let value):
                        for segment in value.segments {
                            guard case .text(let text) = segment else { continue }
                            if !didRecordFirstToken, !text.content.isEmpty,
                               let runID {
                                didRecordFirstToken = true
                                await AgentDiagnosticsRecorder.shared.markFirstToken(
                                    runID: runID
                                )
                            }
                            reasoning = text.content
                            generatedCharacters = max(
                                generatedCharacters,
                                reasoning.count
                            )
                            events.liveReasoningChanged(reasoning)
                        }
                    case .toolOutput(let output):
                        let text = output.segments.compactMap { segment -> String? in
                            guard case .text(let value) = segment else { return nil }
                            return value.content
                        }.joined()
                        if let request = ApprovalRequest(toolOutput: text) {
                            events.approvalRequested(request)
                        }
                    default:
                        break
                    }
                }
            }
            try Task.checkCancellation()
            result = .completed(content: content, reasoning: reasoning)
        } catch OnDeviceStreamingGuard.Failure.repetitiveOutput {
            outcome = .failed
            result = .repetitiveOutput(
                partialContent: content,
                reasoning: reasoning
            )
        } catch where error is CancellationError || Task.isCancelled {
            outcome = .cancelled
            result = .cancelled(partialContent: content, reasoning: reasoning)
        } catch {
            outcome = .failed
            recordedError = error
            result = .failed(
                message: error.localizedDescription,
                partialContent: content,
                reasoning: reasoning
            )
        }

        if let runID {
            if request.backend == .foundationApple {
                let model = SystemLanguageModel.default
                // Beta runtimes may transiently report zero while assets load.
                let reportedContextSize = model.contextSize
                let contextSize = reportedContextSize > 0
                    ? reportedContextSize
                    : 8_192
                let contextTokens = try? await model.tokenCount(
                    for: session.transcript
                )
                await AgentDiagnosticsRecorder.shared.recordContext(
                    runID: runID,
                    tokenCount: contextTokens,
                    contextSize: contextSize
                )
            }
            await AgentDiagnosticsRecorder.shared.finishRun(
                runID: runID,
                outcome: outcome,
                generatedCharacters: generatedCharacters,
                error: recordedError
            )
        }
        events.diagnosticsChanged(nil)
        return result
    }
}
