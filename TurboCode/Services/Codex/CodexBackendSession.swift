import Foundation

/// Provider-neutral adapter over the Codex execution actor.
///
/// It owns cancellation translation and ordered lifecycle events, but no App
/// Server client or UI store. Presentation callbacks are explicit output ports.
actor CodexBackendSession: BackendSession {
    nonisolated let backend: ModelBackend = .codex

    private let runtime: any CodexTurnRunning
    private let turboThreadID: String
    private let workspaceName: String?
    private let agentTuning: AgentTuningConfig
    private let availableSkills: [TurboCodeSkillDefinition]
    private let modelID: String
    private let reasoningEffort: CodexReasoningEffort
    private let persistsModelPreference: Bool
    private let delegationInvoker: (any AgentTaskInvoking)?
    private let runtimeSnapshotChanged: @MainActor @Sendable (
        CodexRuntimeSnapshot,
        Bool
    ) async -> Void
    private let activityStarted: @MainActor @Sendable (
        CodexDynamicToolCall,
        String
    ) async -> Void
    private let activityEnded: @MainActor @Sendable (String) async -> Void
    private let approvalRequested: @MainActor @Sendable (
        ApprovalRequest
    ) async -> Void
    private var activeRun: Task<BackendSessionResult, Never>?

    init(
        runtime: any CodexTurnRunning,
        turboThreadID: String,
        workspaceName: String? = nil,
        agentTuning: AgentTuningConfig,
        availableSkills: [TurboCodeSkillDefinition] = [],
        modelID: String = CodexAppServerClient.lunaModelID,
        reasoningEffort: CodexReasoningEffort = .medium,
        persistsModelPreference: Bool = true,
        delegationInvoker: (any AgentTaskInvoking)? = nil,
        runtimeSnapshotChanged: @escaping @MainActor @Sendable (
            CodexRuntimeSnapshot,
            Bool
        ) async -> Void = { _, _ in },
        activityStarted: @escaping @MainActor @Sendable (
            CodexDynamicToolCall,
            String
        ) async -> Void = { _, _ in },
        activityEnded: @escaping @MainActor @Sendable (
            String
        ) async -> Void = { _ in },
        approvalRequested: @escaping @MainActor @Sendable (
            ApprovalRequest
        ) async -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.turboThreadID = turboThreadID
        self.workspaceName = workspaceName
        self.agentTuning = agentTuning
        self.availableSkills = availableSkills
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.persistsModelPreference = persistsModelPreference
        self.delegationInvoker = delegationInvoker
        self.runtimeSnapshotChanged = runtimeSnapshotChanged
        self.activityStarted = activityStarted
        self.activityEnded = activityEnded
        self.approvalRequested = approvalRequested
    }

    func run(
        request: TurnRequest,
        events: BackendSessionEvents
    ) async -> BackendSessionResult {
        activeRun?.cancel()
        let runtime = self.runtime
        let turboThreadID = self.turboThreadID
        let workspaceName = self.workspaceName
        let agentTuning = self.agentTuning
        let availableSkills = self.availableSkills
        let modelID = self.modelID
        let reasoningEffort = self.reasoningEffort
        let persistsModelPreference = self.persistsModelPreference
        let delegationInvoker = self.delegationInvoker
        let runtimeSnapshotChanged = self.runtimeSnapshotChanged
        let activityStarted = self.activityStarted
        let activityEnded = self.activityEnded
        let approvalRequested = self.approvalRequested
        let toolTimings = CodexToolTimingRegistry()

        let task = Task {
            await events.emit(.started(request))
            await events.emit(
                .phaseChanged(
                    turnID: request.id,
                    phase: .streaming,
                    at: Date()
                )
            )

            let result: BackendSessionResult
            do {
                let response = try await runtime.runTurn(
                    request: CodexTurnRequest(
                        turnID: request.id,
                        turboThreadID: turboThreadID,
                        prompt: request.prompt,
                        workspaceRoot: request.workspaceRoot,
                        workspaceName: workspaceName,
                        agentTuning: agentTuning,
                        availableSkills: availableSkills,
                        modelID: modelID,
                        reasoningEffort: reasoningEffort,
                        persistsModelPreference: persistsModelPreference,
                        delegationInvoker: delegationInvoker
                    ),
                    events: CodexTurnEvents(
                        runtimeSnapshotChanged: { snapshot, persistsPreference in
                            await runtimeSnapshotChanged(
                                snapshot,
                                persistsPreference
                            )
                        },
                        liveAssistantChanged: { text in
                            await events.emit(
                                .assistantTextChanged(
                                    turnID: request.id,
                                    text: text
                                )
                            )
                        },
                        liveReasoningChanged: { text in
                            await events.emit(
                                .reasoningTextChanged(
                                    turnID: request.id,
                                    text: text
                                )
                            )
                        },
                        activityStarted: { call, summary in
                            await activityStarted(call, summary)
                            let startedAt = Date()
                            await toolTimings.record(
                                startedAt,
                                for: call.callID
                            )
                            // Tool events are the authoritative lifecycle edge.
                            // Emitting an additional phase event here would
                            // make the coordinator race two equivalent updates.
                            await events.emit(
                                .toolStarted(
                                    Self.toolCall(
                                        from: call,
                                        turnID: request.id,
                                        startedAt: startedAt
                                    )
                                )
                            )
                        },
                        activityEnded: { id in
                            // Presentation cleanup is separate from lifecycle;
                            // `.toolFinished` below returns the runtime to
                            // streaming before this activity is dismissed.
                            await activityEnded(id)
                        },
                        toolFinished: { call, result, receipt in
                            let startedAt = await toolTimings.remove(
                                call.callID
                            )
                            await events.emit(
                                .toolFinished(
                                    Self.toolResult(
                                        from: result,
                                        call: call,
                                        turnID: request.id,
                                        startedAt: startedAt,
                                        receipt: receipt
                                    )
                                )
                            )
                        },
                        approvalRequested: { request in
                            await approvalRequested(request)
                        }
                    )
                )
                result = BackendSessionResult(
                    assistantText: response.assistantText,
                    reasoningText: response.reasoningText,
                    outcome: .succeeded
                )
            } catch where error is CancellationError || Task.isCancelled {
                result = BackendSessionResult(
                    outcome: .cancelled(reason: "The turn was interrupted.")
                )
            } catch let codexError as CodexAppServerError
                where codexError.requiresChatGPTLogin {
                result = BackendSessionResult(
                    outcome: .failed(
                        TurnFailure(
                            code: "codex.authentication",
                            message: "Codex authentication is required.",
                            isRecoverable: true
                        )
                    )
                )
            } catch {
                result = BackendSessionResult(
                    outcome: .failed(
                        TurnFailure(
                            code: "codex.provider",
                            message: error.localizedDescription
                        )
                    )
                )
            }

            await events.emit(
                .completed(
                    turnID: request.id,
                    outcome: result.outcome,
                    at: Date()
                )
            )
            return result
        }
        activeRun = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task {
                await runtime.interrupt()
            }
        }
        if activeRun != nil {
            activeRun = nil
        }
        return result
    }

    func interrupt() async {
        activeRun?.cancel()
        await runtime.interrupt()
    }

    nonisolated private static func toolCall(
        from call: CodexDynamicToolCall,
        turnID: TurnID,
        startedAt: Date = Date()
    ) -> ToolCall {
        ToolCall(
            id: call.callID,
            turnID: turnID,
            name: call.tool,
            argumentsJSON: jsonString(call.arguments),
            startedAt: startedAt
        )
    }

    nonisolated private static func toolResult(
        from result: CodexDynamicToolResult,
        call: CodexDynamicToolCall,
        turnID: TurnID,
        startedAt: Date?,
        receipt: ToolReceipt?
    ) -> ToolResult {
        ToolResult(
            id: call.callID,
            turnID: turnID,
            status: result.succeeded ? .succeeded : .failed,
            output: result.text,
            durationMilliseconds: startedAt.map {
                max(0, Int(Date().timeIntervalSince($0) * 1_000))
            },
            receipt: receipt
        )
    }

    nonisolated private static func jsonString(_ value: CodexJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
/// Request-local timing state receives callbacks on the engine executor and
/// remains independent from both the backend-session actor and MainActor.
private actor CodexToolTimingRegistry {
    private var startTimes: [String: Date] = [:]

    func record(_ date: Date, for callID: String) {
        startTimes[callID] = date
    }

    func remove(_ callID: String) -> Date? {
        startTimes.removeValue(forKey: callID)
    }
}
