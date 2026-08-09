import Foundation
import FoundationModels

/// Runtime dependencies selected by routing before a worker starts.
nonisolated struct AgentTaskRunContext: Sendable {
    let model: any LanguageModel
    let toolPlan: ModelToolPlan
    let tools: [any Tool]
    let workspaceRoot: String
    let instructions: String
    let temperature: Double?
    let reasoningLevel: ContextOptions.ReasoningLevel?

    init(
        model: any LanguageModel,
        toolPlan: ModelToolPlan,
        tools: [any Tool],
        workspaceRoot: String = "",
        instructions: String,
        temperature: Double?,
        reasoningLevel: ContextOptions.ReasoningLevel?
    ) {
        self.model = model
        self.toolPlan = toolPlan
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
}

/// Correlates a worker tool result without requiring transcript inspection.
nonisolated struct AgentTaskToolOutputEvent: Sendable {
    let taskID: String
    let attemptID: String
    let call: Transcript.ToolCall
    let output: Transcript.ToolOutput
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
        let pathScope = AgentTaskPathScope(
            workspaceRoot: context.workspaceRoot,
            suggestedPaths: envelope.suggestedScope
        )
        let permittedNames = AgentTaskToolPolicy.permittedNames(
            envelope: envelope,
            plan: context.toolPlan,
            scope: pathScope
        )
        let requestedNames = Set(envelope.allowedTools.map(\.rawValue))
            .intersection(context.toolPlan.registeredIDs.map(\.rawValue))
        if let incompatibleName = requestedNames.subtracting(permittedNames).sorted().first {
            // Fail before creating a model session: silently removing a broad
            // tool can make the model claim completion without doing the work.
            throw AgentTaskWorkerError.toolNotAllowed(incompatibleName)
        }
        let tools = context.tools.compactMap { tool -> (any Tool)? in
            guard permittedNames.contains(tool.name) else { return nil }
            // The worker receives scoped instances; direct tool validation is
            // retained even though the runner also preflights each call.
            if let read = tool as? ReadFileTool {
                return read.restricted(to: pathScope)
            }
            if let search = tool as? GrepTool {
                return search.restricted(to: pathScope)
            }
            if let edit = tool as? EditFileTool {
                return edit.restricted(to: pathScope)
            }
            if let list = tool as? ListWorkspaceTool {
                return list.restricted(to: pathScope)
            }
            if let map = tool as? SwiftWorkspaceMapTool {
                return map.restricted(to: pathScope)
            }
            if let fileSystem = tool as? FileSystemTool {
                return fileSystem.restricted(to: pathScope)
            }
            if let writer = tool as? WriteOnDeviceTool {
                return writer.restricted(to: pathScope)
            }
            if let remover = tool as? RemoveFileTool {
                return remover.restricted(to: pathScope)
            }
            if let git = tool as? GitTool {
                return git.restricted(to: pathScope)
            }
            if let bash = tool as? BashTool {
                return bash.restricted(to: pathScope)
            }
            if let xcode = tool as? XcodeProjectTool {
                return xcode.restricted(to: pathScope)
            }
            if let swiftPM = tool as? SwiftPackageManagerTool {
                return swiftPM.restricted(to: pathScope)
            }
            return tool
        }
        let gate = AgentTaskExecutionGate(
            allowedToolNames: permittedNames,
            maximumToolCalls: envelope.budget.maximumToolCalls,
            pathScope: pathScope
        )
        let session = LanguageModelSession(
            profile: DelegateProfile(
                instructions: context.instructions,
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
                    let failure = await gate.beginTool(call)
                    guard !Task.isCancelled else {
                        withUnsafeCurrentTask { task in task?.cancel() }
                        return
                    }
                    await events.toolStarted(
                        AgentTaskToolCallEvent(
                            taskID: envelope.taskID,
                            attemptID: envelope.attemptID,
                            call: call
                        )
                    )
                    if failure != nil {
                        // onToolCall cannot throw. Cancelling the current model
                        // task stops execution before another tool can begin.
                        withUnsafeCurrentTask { task in task?.cancel() }
                    }
                },
                onToolEnd: { call, output in
                    await events.toolFinished(
                        AgentTaskToolOutputEvent(
                            taskID: envelope.taskID,
                            attemptID: envelope.attemptID,
                            call: call,
                            output: output
                        )
                    )
                }
            ),
            history: []
        )

        do {
            var content = ""
            let prompt = try Self.encodedPrompt(envelope)
            for try await snapshot in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                if !snapshot.content.isEmpty {
                    content = snapshot.content
                }
            }
            if let failure = await gate.failure {
                throw failure
            }
            return content
        } catch {
            if let failure = await gate.failure {
                throw failure
            }
            throw error
        }
    }

    private static func encodedPrompt(_ envelope: AgentTaskEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentTaskWorkerError.invalidEnvelopeEncoding
        }
        // A stable JSON payload keeps the task contract independent from
        // transcript formatting and lets every provider receive identical data.
        return "Complete the following structured task:\n\(json)"
    }
}

/// Resolves the effective worker surface from the catalog-backed plan and the
/// narrower per-task allowlist. Neither the prompt nor either input alone can
/// grant a capability.
nonisolated enum AgentTaskToolPolicy {
    static func permittedNames(
        envelope: AgentTaskEnvelope,
        plan: ModelToolPlan,
        scope: AgentTaskPathScope? = nil
    ) -> Set<String> {
        let names = Set(envelope.allowedTools.map(\.rawValue))
            .intersection(plan.registeredIDs.map(\.rawValue))
        guard let scope, !scope.isWorkspaceWide else { return names }

        // These tools can validate every path-bearing argument against the
        // delegated boundary. Repository/build/shell tools remain workspace
        // wide because their operations inherently span more than one path.
        let scopeCompatible: Set<String> = [
            ToolCapabilityID.turboCodeGuide.rawValue,
            ToolCapabilityID.listWorkspace.rawValue,
            ToolCapabilityID.swiftWorkspaceMap.rawValue,
            ToolCapabilityID.readFile.rawValue,
            ToolCapabilityID.searchWorkspace.rawValue,
            ToolCapabilityID.fileSystem.rawValue,
            ToolCapabilityID.editFile.rawValue,
            ToolCapabilityID.writeOnDevice.rawValue,
            ToolCapabilityID.removeFile.rawValue,
            ToolCapabilityID.loadSkill.rawValue
        ]
        return names.intersection(scopeCompatible)
    }
}

/// Counts actual worker tool starts and records the first policy violation.
actor AgentTaskExecutionGate {
    private let allowedToolNames: Set<String>
    private let maximumToolCalls: Int
    private let pathScope: AgentTaskPathScope?
    private var toolCallCount = 0
    private(set) var failure: AgentTaskWorkerError?

    init(
        allowedToolNames: Set<String>,
        maximumToolCalls: Int,
        pathScope: AgentTaskPathScope? = nil
    ) {
        self.allowedToolNames = allowedToolNames
        self.maximumToolCalls = maximumToolCalls
        self.pathScope = pathScope
    }

    func beginTool(named name: String) -> AgentTaskWorkerError? {
        guard failure == nil else { return failure }
        guard allowedToolNames.contains(name) else {
            failure = .toolNotAllowed(name)
            return failure
        }
        guard toolCallCount < maximumToolCalls else {
            failure = .toolLimitReached
            return failure
        }
        toolCallCount += 1
        return nil
    }

    /// Preflights path-bearing calls before their concrete tool can mutate or
    /// disclose data. Calls without a path remain governed by global policy.
    func beginTool(_ call: Transcript.ToolCall) -> AgentTaskWorkerError? {
        guard failure == nil else { return failure }
        guard allowedToolNames.contains(call.toolName) else {
            failure = .toolNotAllowed(call.toolName)
            return failure
        }
        if let pathScope,
           let path = Self.pathArgument(in: call) {
            do {
                try pathScope.validate(path)
            } catch {
                failure = .pathOutsideScope(path)
                return failure
            }
        }
        guard toolCallCount < maximumToolCalls else {
            failure = .toolLimitReached
            return failure
        }
        toolCallCount += 1
        return nil
    }

    private static func pathArgument(
        in call: Transcript.ToolCall
    ) -> String? {
        let property: String
        switch call.toolName {
        case "read_file", "edit_file":
            property = "filePath"
        case "write_ondevice":
            property = "fileName"
        case "remove_file", "grep", "list_workspace":
            property = "path"
        case "swift_workspace_map":
            property = "path"
        case "file_system":
            property = "path"
        default:
            return nil
        }
        return try? call.arguments.value(String.self, forProperty: property)
    }

    var count: Int { toolCallCount }
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
