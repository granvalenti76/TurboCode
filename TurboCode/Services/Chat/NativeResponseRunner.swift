import Foundation
import FoundationModels
import FoundationModelsUtilities

/// Runs one FoundationModels turn and reports domain-neutral streaming state.
///
/// The runner owns provider streaming and diagnostics only. It deliberately
/// does not know about conversations, timeline blocks, workspace mutations, or
/// navigation; ChatStore decides how the returned outcome is presented.
@MainActor
final class NativeResponseRunner: NativeResponseRunning {
    /// Normalizes reasoning updates that may arrive either as a cumulative
    /// snapshot or as an incremental fragment, depending on the provider
    /// bridge and Foundation Models runtime.
    nonisolated static func accumulatedReasoning(
        previous: String,
        incoming: String
    ) -> String {
        guard !incoming.isEmpty else { return previous }
        guard !previous.isEmpty else { return incoming }

        // Cumulative snapshots supersede the previous value. A shorter stale
        // snapshot is ignored so a transient runtime rollback cannot truncate
        // the reasoning already visible to the user.
        if incoming.hasPrefix(previous) || previous.hasPrefix(incoming) {
            return incoming.count >= previous.count ? incoming : previous
        }

        // Providers that expose deltas need the new fragment appended.
        return previous + incoming
    }

    struct Request {
        let prompt: String
        let backend: ModelBackend
        let mode: OrchestratorMode
        let workspaceKind: String
        /// Llama's runtime context is discovered from the server rather than
        /// trusting the profile JSON, which may describe a different launch.
        let serverURL: String?
    }

    enum Outcome {
        case completed(content: String, reasoning: String)
        case repetitiveOutput(partialContent: String, reasoning: String)
        case cancelled(partialContent: String, reasoning: String)
        case failed(message: String, partialContent: String, reasoning: String)
    }

    struct Events: @unchecked Sendable {
        let diagnosticsChanged: @MainActor @Sendable (String?) -> Void
        let liveContentChanged: @MainActor @Sendable (String) -> Void
        let liveReasoningChanged: @MainActor @Sendable (String) -> Void
        let approvalRequested: @MainActor @Sendable (ApprovalRequest) -> Void
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

        let llamaContextSize = request.backend == .llamaServer
            ? await LlamaServerRuntimeProbe.contextSize(
                from: request.serverURL
            )
            : nil

        var outcome: AgentRunOutcome = .success
        var recordedError: Error?
        var generatedCharacters = 0
        var didRecordFirstToken = false
        var content = ""
        var reasoning = ""
        var latestInputTokenCount: Int?
        var latestUsage: LanguageModelSession.Usage?
        var result: Outcome
        let reasoningRelayID: UUID?

        if request.backend == .llamaServer {
            reasoningRelayID = await ReasoningStreamRelay.shared.install { delta in
                events.liveReasoningChanged(delta)
            }
        } else {
            reasoningRelayID = nil
        }

        defer {
            if let reasoningRelayID {
                Task {
                    await ReasoningStreamRelay.shared.remove(reasoningRelayID)
                }
            }
        }

        do {
            for try await snapshot in session.streamResponse(to: request.prompt) {
                try Task.checkCancellation()

                if request.backend == .foundationApple, let runID {
                    await AgentDiagnosticsRecorder.shared.recordUsage(
                        runID: runID,
                        usage: snapshot.usage
                    )
                } else if request.backend == .llamaServer {
                    // Llama reports cumulative usage on the stream's trailing
                    // snapshot. Keep only the latest value locally so metrics
                    // collection cannot add one actor hop per token.
                    latestUsage = snapshot.usage
                    latestInputTokenCount = snapshot.usage.input.totalTokenCount
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

                var snapshotReasoning = ""
                for entry in snapshot.transcriptEntries {
                    switch entry {
                    case .reasoning(let value):
                        for segment in value.segments {
                            guard case .text(let text) = segment else { continue }
                            snapshotReasoning += text.content
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

                if !snapshotReasoning.isEmpty {
                    if !didRecordFirstToken, let runID {
                        didRecordFirstToken = true
                        await AgentDiagnosticsRecorder.shared.markFirstToken(
                            runID: runID
                        )
                    }
                    reasoning = Self.accumulatedReasoning(
                        previous: reasoning,
                        incoming: snapshotReasoning
                    )
                    generatedCharacters = max(
                        generatedCharacters,
                        reasoning.count
                    )
                    if request.backend != .llamaServer {
                        events.liveReasoningChanged(reasoning)
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
            } else if request.backend == .llamaServer {
                if let latestUsage {
                    await AgentDiagnosticsRecorder.shared.recordUsage(
                        runID: runID,
                        usage: latestUsage
                    )
                }
                if let llamaContextSize {
                    await AgentDiagnosticsRecorder.shared.recordContext(
                        runID: runID,
                        tokenCount: latestInputTokenCount,
                        contextSize: llamaContextSize
                    )
                }
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

/// Reads only server-owned runtime metadata. A failed probe is intentionally
/// ignored: inference must remain available when an older llama-server build
/// omits the endpoint or the local server is restarting.
private enum LlamaServerRuntimeProbe {
    static func contextSize(from baseURL: String?) async -> Int? {
        guard let baseURL,
              let base = URL(string: baseURL) else { return nil }

        let endpoint = base.deletingLastPathComponent()
            .appendingPathComponent("props")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let settings = object["default_generation_settings"] as? [String: Any],
              let value = settings["n_ctx"] as? NSNumber else {
            return nil
        }
        return value.intValue > 0 ? value.intValue : nil
    }
}

/// Injectable boundary for one native response lifecycle.
///
/// Production uses ``NativeResponseRunner``. Keeping the coordinator dependent
/// on this narrow protocol lets release scenarios exercise the complete chat,
/// delegation, and cancellation path without starting a variable model stream.
@MainActor
protocol NativeResponseRunning {
    func run(
        session: LanguageModelSession,
        request: NativeResponseRunner.Request,
        events: NativeResponseRunner.Events
    ) async -> NativeResponseRunner.Outcome
}
