import Foundation
import FoundationModels

/// Runtime dependencies selected by routing before a worker starts.
nonisolated struct AgentTaskRunContext: Sendable {
    let model: any LanguageModel
    let tools: [any Tool]
    let workspaceRoot: String
    let instructions: String
    let temperature: Double?
    let reasoningLevel: ContextOptions.ReasoningLevel?

    init(
        model: any LanguageModel,
        tools: [any Tool],
        workspaceRoot: String = "",
        instructions: String,
        temperature: Double?,
        reasoningLevel: ContextOptions.ReasoningLevel?
    ) {
        self.model = model
        self.tools = tools
        self.workspaceRoot = workspaceRoot
        self.instructions = instructions
        self.temperature = temperature
        self.reasoningLevel = reasoningLevel
    }
}

/// Correlates a worker tool call with the structured task that produced it.
nonisolated struct AgentTaskToolCallEvent: Sendable {
    let taskID: String
    let attemptID: String
    let call: Transcript.ToolCall
    /// The owning application turn, when this worker was launched from one.
    let turnID: TurnID?

    init(
        taskID: String,
        attemptID: String,
        call: Transcript.ToolCall,
        turnID: TurnID? = nil
    ) {
        self.taskID = taskID
        self.attemptID = attemptID
        self.call = call
        self.turnID = turnID
    }
}

/// Correlates a worker tool result without requiring transcript inspection.
nonisolated struct AgentTaskToolOutputEvent: Sendable {
    let taskID: String
    let attemptID: String
    let call: Transcript.ToolCall
    let output: Transcript.ToolOutput
    /// The owning application turn, when this worker was launched from one.
    let turnID: TurnID?

    init(
        taskID: String,
        attemptID: String,
        call: Transcript.ToolCall,
        output: Transcript.ToolOutput,
        turnID: TurnID? = nil
    ) {
        self.taskID = taskID
        self.attemptID = attemptID
        self.call = call
        self.output = output
        self.turnID = turnID
    }
}

/// Typed lifecycle callbacks consumed by diagnostics now and Activity in M2.
nonisolated struct AgentTaskRunnerEvents: Sendable {
    static let none = AgentTaskRunnerEvents()

    let toolStarted: @Sendable (AgentTaskToolCallEvent) async -> Void
    let toolFinished: @Sendable (AgentTaskToolOutputEvent) async -> Void
    let verificationStarted: @Sendable (
        String,
        String,
        VerificationRequest
    ) async -> Void
    let verificationFinished: @Sendable (
        AgentTaskVerificationReceipt
    ) async -> Void

    init(
        toolStarted: @escaping @Sendable (
            AgentTaskToolCallEvent
        ) async -> Void = { _ in },
        toolFinished: @escaping @Sendable (
            AgentTaskToolOutputEvent
        ) async -> Void = { _ in },
        verificationStarted: @escaping @Sendable (
            String,
            String,
            VerificationRequest
        ) async -> Void = { _, _, _ in },
        verificationFinished: @escaping @Sendable (
            AgentTaskVerificationReceipt
        ) async -> Void = { _ in }
    ) {
        self.toolStarted = toolStarted
        self.toolFinished = toolFinished
        self.verificationStarted = verificationStarted
        self.verificationFinished = verificationFinished
    }
}

/// Provider-independent execution boundary used by coordinator adapters.
nonisolated protocol AgentTaskRunning: Sendable {
    @MainActor
    func run(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async -> AgentTaskResult
}

/// The provider-specific streaming primitive kept behind the bounded runner.
nonisolated protocol AgentTaskWorkerExecuting: Sendable {
    @MainActor
    func execute(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String
}

/// Applies timeout, cancellation, validation, and result mapping around a
/// provider worker. Provider adapters cannot bypass these terminal outcomes.
nonisolated struct BoundedAgentTaskRunner: AgentTaskRunning {
    private let worker: any AgentTaskWorkerExecuting
    private let verifier: (any AgentTaskVerificationRunning)?

    init(
        worker: any AgentTaskWorkerExecuting = FoundationModelsTaskWorker(),
        verifier: (any AgentTaskVerificationRunning)? = nil
    ) {
        self.worker = worker
        self.verifier = verifier
    }

    @MainActor
    func run(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async -> AgentTaskResult {
        do {
            let validated = try envelope.validated()
            // Cancellation is an execution boundary: never create a worker
            // session after the outer response has already been stopped.
            try Task.checkCancellation()
            let mutationJournal = AgentTaskMutationJournal()
            let trackedEvents = AgentTaskRunnerEvents(
                toolStarted: events.toolStarted,
                toolFinished: { event in
                    await mutationJournal.recordToolCompletion(event)
                    await events.toolFinished(event)
                },
                verificationStarted: events.verificationStarted,
                verificationFinished: events.verificationFinished
            )
            let content = try await executeWithTimeout(
                envelope: validated,
                context: context,
                events: trackedEvents
            )
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failureResult(
                    envelope: validated,
                    reason: .invalidResult,
                    detail: "The worker returned an empty response."
                )
            }
            if let path = await mutationJournal.revisionConflictPath {
                let detail = """
                '\(path)' changed after the worker read it. No conflicting \
                edit was applied.
                """
                return try AgentTaskResult(
                    taskID: validated.taskID,
                    attemptID: validated.attemptID,
                    outcome: .failed,
                    technicalSummary: content,
                    failureReason: .revisionConflict,
                    failureDetail: detail,
                    unresolvedWork: ["Re-read \(path) before editing again."]
                )
            }
            guard validated.verificationRequest != .none else {
                return try AgentTaskResult(
                    taskID: validated.taskID,
                    attemptID: validated.attemptID,
                    outcome: .completed,
                    technicalSummary: content
                )
            }
            try Task.checkCancellation()
            guard let verifier else {
                return failureResult(
                    envelope: validated,
                    reason: .verificationFailed,
                    detail: "No deterministic verification runner is configured."
                )
            }
            await events.verificationStarted(
                validated.taskID,
                validated.attemptID,
                validated.verificationRequest
            )
            try Task.checkCancellation()
            let mutationSequence = await mutationJournal.sequence
            let receipt = await verifier.verify(
                envelope: validated,
                context: context,
                mutationSequence: mutationSequence
            )
            await events.verificationFinished(receipt)
            if receipt.cancelled {
                throw CancellationError()
            }
            let latestMutationSequence = await mutationJournal.sequence
            guard latestMutationSequence == receipt.mutationSequence else {
                // A late provider callback or external adapter mutation makes
                // the evidence stale even when the build/test itself passed.
                // Never publish Verified against a newer workspace state.
                let detail = """
                A workspace modification occurred after verification began. \
                Run verification again against the latest changes.
                """
                return try AgentTaskResult(
                    taskID: validated.taskID,
                    attemptID: validated.attemptID,
                    outcome: .failed,
                    technicalSummary: content,
                    receiptIDs: [receipt.id],
                    verification: AgentVerificationResult(
                        status: .failed,
                        receiptID: receipt.id,
                        detail: detail
                    ),
                    failureReason: .verificationInvalidated,
                    failureDetail: detail,
                    unresolvedWork: ["Run verification again."]
                )
            }
            if !receipt.succeeded {
                return try AgentTaskResult(
                    taskID: validated.taskID,
                    attemptID: validated.attemptID,
                    outcome: .failed,
                    technicalSummary: content,
                    receiptIDs: [receipt.id],
                    verification: AgentVerificationResult(
                        status: .failed,
                        receiptID: receipt.id,
                        detail: receipt.summary
                    ),
                    failureReason: .verificationFailed,
                    failureDetail: receipt.summary
                )
            }
            return try AgentTaskResult(
                taskID: validated.taskID,
                attemptID: validated.attemptID,
                outcome: .verified,
                technicalSummary: content,
                receiptIDs: [receipt.id],
                verification: AgentVerificationResult(
                    status: .passed,
                    receiptID: receipt.id,
                    detail: receipt.summary
                )
            )
        } catch AgentTaskWorkerError.timedOut {
            return failureResult(
                envelope: envelope,
                reason: .timedOut,
                detail: "The worker exceeded the task timeout."
            )
        } catch AgentTaskWorkerError.toolLimitReached {
            return failureResult(
                envelope: envelope,
                reason: .toolLimitReached,
                detail: "The worker reached its tool-call limit."
            )
        } catch AgentTaskWorkerError.toolNotAllowed(let name) {
            return failureResult(
                envelope: envelope,
                reason: .toolNotAllowed,
                detail: "The worker attempted the disallowed tool '\(name)'."
            )
        } catch AgentTaskWorkerError.pathOutsideScope(let path) {
            return failureResult(
                envelope: envelope,
                reason: .pathOutsideScope,
                detail: "The worker attempted to access '\(path)' outside the task scope."
            )
        } catch where error is CancellationError || Task.isCancelled {
            return (try? AgentTaskResult(
                taskID: envelope.taskID,
                attemptID: envelope.attemptID,
                outcome: .cancelled,
                technicalSummary: "The worker task was cancelled.",
                failureReason: .cancelled
            )) ?? fallbackInvalidResult(envelope: envelope)
        } catch {
            return failureResult(
                envelope: envelope,
                reason: .workerFailed,
                detail: error.localizedDescription
            )
        }
    }

    @MainActor
    private func executeWithTimeout(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String {
        let race = AgentTaskFirstResult<String>()
        let worker = self.worker
        let workerTask = Task { @MainActor in
            let result: Result<String, Error>
            do {
                result = .success(
                    try await worker.execute(
                        envelope: envelope,
                        context: context,
                        events: events
                    )
                )
            } catch {
                result = .failure(error)
            }
            await race.resolve(result)
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(envelope.budget.timeoutSeconds))
            } catch {
                return
            }
            workerTask.cancel()
            await race.resolve(.failure(AgentTaskWorkerError.timedOut))
        }

        return try await withTaskCancellationHandler {
            defer {
                workerTask.cancel()
                timeoutTask.cancel()
            }
            return try await race.value()
        } onCancel: {
            workerTask.cancel()
            timeoutTask.cancel()
            Task {
                await race.resolve(.failure(CancellationError()))
            }
        }
    }

    private func failureResult(
        envelope: AgentTaskEnvelope,
        reason: AgentTaskFailureReason,
        detail: String
    ) -> AgentTaskResult {
        (try? AgentTaskResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            outcome: .failed,
            technicalSummary: detail,
            failureReason: reason,
            failureDetail: detail
        )) ?? fallbackInvalidResult(envelope: envelope)
    }

    private func fallbackInvalidResult(envelope: AgentTaskEnvelope) -> AgentTaskResult {
        // The envelope is validated before normal execution. This fallback is
        // only for malformed direct callers and preserves a terminal response.
        AgentTaskResult.invalidContractResult(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID
        )
    }
}

/// Foundation Models implementation of one worker session.
nonisolated struct FoundationModelsTaskWorker: AgentTaskWorkerExecuting {
    @MainActor
    func execute(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String {
        // The coordinator makes one capability decision only. Coding receives
        // the complete catalog-backed worker plan; text receives no tools. Each
        // concrete tool still enforces the workspace root and its normal review
        // or approval policy, so a second model-authored path gate adds failure
        // modes without widening access.
        let tools = DelegatedWorkerToolPolicy.tools(
            for: envelope.mode,
            availableTools: context.tools
        )
        let instructions = envelope.mode == .coding
            ? context.instructions
            : """
              Complete the delegated goal and return useful prose to the \
              coordinator. This is a text-only task: do not inspect or claim \
              to modify the workspace.
              """
        let session = LanguageModelSession(
            profile: DelegateProfile(
                instructions: instructions,
                tools: tools,
                model: context.model,
                temperature: context.temperature,
                reasoningLevel: context.reasoningLevel,
                onToolStart: { call in
                    // Foundation Models cannot throw from this callback. Cancel
                    // its current task before publishing a new tool when Stop
                    // raced with provider dispatch.
                    guard !Task.isCancelled else {
                        withUnsafeCurrentTask { task in task?.cancel() }
                        return
                    }
                    await events.toolStarted(
                        AgentTaskToolCallEvent(
                            taskID: envelope.taskID,
                            attemptID: envelope.attemptID,
                            call: call,
                            turnID: envelope.parentTurnID
                        )
                    )
                },
                onToolEnd: { call, output in
                    await events.toolFinished(
                        AgentTaskToolOutputEvent(
                            taskID: envelope.taskID,
                            attemptID: envelope.attemptID,
                            call: call,
                            output: output,
                            turnID: envelope.parentTurnID
                        )
                    )
                }
            ),
            history: []
        )

        var content = ""
        let prompt = try Self.encodedPrompt(envelope)
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            if !snapshot.content.isEmpty {
                content = snapshot.content
            }
        }
        return content
    }

    private static func encodedPrompt(_ envelope: AgentTaskEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            WorkerTaskPrompt(goal: envelope.goal)
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentTaskWorkerError.invalidEnvelopeEncoding
        }
        // The worker needs the task, not the coordinator/runtime bookkeeping.
        // Its available tool definitions already communicate coding vs text.
        return "Complete the following delegated task:\n\(json)"
    }
}

/// Model-facing payload kept deliberately smaller than AgentTaskEnvelope.
private nonisolated struct WorkerTaskPrompt: Encodable, Sendable {
    let goal: String
}

/// Binary worker capability policy shared by runtime and focused evaluations.
nonisolated enum DelegatedWorkerToolPolicy {
    static func tools(
        for mode: DelegatedWorkerMode,
        availableTools: [any Tool]
    ) -> [any Tool] {
        mode == .coding ? availableTools : []
    }
}

/// Resolves an unstructured worker/timeout race exactly once. The loser is
/// cancelled by the runner, so the timeout path never waits for a stuck stream.
private actor AgentTaskFirstResult<Value: Sendable> {
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

nonisolated enum AgentTaskWorkerError: LocalizedError, Sendable, Equatable {
    case timedOut
    case toolLimitReached
    case toolNotAllowed(String)
    case pathOutsideScope(String)
    case invalidEnvelopeEncoding

    var errorDescription: String? {
        switch self {
        case .timedOut:
            "The worker timed out."
        case .toolLimitReached:
            "The worker reached its tool-call limit."
        case .toolNotAllowed(let name):
            "The worker attempted the disallowed tool '\(name)'."
        case .pathOutsideScope(let path):
            "The worker attempted a path outside task scope: '\(path)'."
        case .invalidEnvelopeEncoding:
            "The structured task could not be encoded."
        }
    }
}
