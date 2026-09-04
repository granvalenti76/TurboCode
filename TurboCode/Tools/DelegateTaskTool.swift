import Foundation
import FoundationModels

/// Minimal provider-facing choice for one delegated worker turn.
///
/// Runtime identifiers, safety timeout, and workspace confinement are owned by
/// TurboCode. Keeping them out of the model schema prevents coordinators from
/// inventing invalid policy values instead of describing the work itself.
@Generable
struct DelegateTaskArguments {
    /// Coarse worker mode: coding gets the configured tool bundle, text gets none.
    @Guide(.anyOf(["coding", "text"]))
    var mode: String = "coding"
    /// Concrete outcome the worker must produce.
    var goal: String

    func envelope() throws -> AgentTaskEnvelope {
        guard let workerMode = DelegatedWorkerMode(rawValue: mode) else {
            throw DelegateTaskAdapterError.unknownMode(mode)
        }
        let taskID = UUID().uuidString
        return try AgentTaskEnvelope(
            taskID: taskID,
            attemptID: "\(taskID)-attempt-1",
            mode: workerMode,
            goal: goal,
            acceptanceCriteria: ["Complete the delegated goal and report the result."],
            // The worker may use any workspace path its registered tools allow.
            // Per-path restrictions belong in a future explicit UI, not in
            // coordinator-authored prose masquerading as policy.
            suggestedScope: [],
            verificationRequest: .none,
            budget: .default
        )
    }
}

nonisolated enum DelegateTaskAdapterError: LocalizedError, Sendable, Equatable {
    case unknownMode(String)

    var errorDescription: String? {
        switch self {
        case .unknownMode(let mode):
            "Unknown delegated worker mode '\(mode)'."
        }
    }
}

/// Provider-neutral worker invocation used by both coordinator adapters.
nonisolated protocol AgentTaskInvoking: Sendable {
    @MainActor
    func invoke(_ envelope: AgentTaskEnvelope) async -> AgentTaskResult
}

/// Optional extension of the invocation boundary for adapters that can carry
/// the owning application turn into a worker envelope. Keeping this separate
/// preserves older test and provider invokers while the harness migrates them.
nonisolated protocol TurnAwareAgentTaskInvoking: AgentTaskInvoking {
    @MainActor
    func invoke(
        _ envelope: AgentTaskEnvelope,
        parentTurnID: TurnID?
    ) async -> AgentTaskResult
}

nonisolated enum AgentTaskInvocation {
    @MainActor
    static func invoke(
        _ invoker: any AgentTaskInvoking,
        envelope: AgentTaskEnvelope,
        parentTurnID: TurnID?
    ) async -> AgentTaskResult {
        if let turnAware = invoker as? any TurnAwareAgentTaskInvoking {
            return await turnAware.invoke(
                envelope,
                parentTurnID: parentTurnID
            )
        }
        return await invoker.invoke(envelope)
    }
}

/// Stable acknowledgement returned when the harness retains a delegated task
/// after the invoking model turn is free to settle.
nonisolated struct DelegatedTaskReceipt: Codable, Sendable, Hashable {
    let status: String
    let taskID: String
    let attemptID: String

    init(envelope: AgentTaskEnvelope) {
        status = "accepted"
        taskID = envelope.taskID
        attemptID = envelope.attemptID
    }
}

/// Application-owned admission port shared by Foundation Models, Codex, and
/// the explicit `/task` command. The invoker remains immutable worker context;
/// the receiver decides how to retain and surface its asynchronous lifetime.
typealias DelegatedTaskBackgroundSubmission = @Sendable (
    _ envelope: AgentTaskEnvelope,
    _ invoker: any AgentTaskInvoking,
    _ parentTurnID: TurnID?
) async throws -> DelegatedTaskReceipt

nonisolated enum DelegatedTaskSupervisorError: LocalizedError, Sendable {
    case workerAlreadyRunning
    case missingOriginatingConversation

    var errorDescription: String? {
        switch self {
        case .workerAlreadyRunning:
            "A delegated task is already running in the background."
        case .missingOriginatingConversation:
            "TurboCode could not identify the originating conversation."
        }
    }
}

/// Retains one background worker independently from the conversational runtime.
/// Single-flight admission prevents two delegated workers from racing over the
/// same workspace while the first version of this feature is evaluated.
actor DelegatedTaskSupervisor {
    typealias Completion = @Sendable (AgentTaskResult) async -> Void

    private var activeIdentity: String?
    private var operation: Task<Void, Never>?

    func submit(
        envelope: AgentTaskEnvelope,
        invoker: any AgentTaskInvoking,
        parentTurnID: TurnID?,
        completion: @escaping Completion
    ) throws -> DelegatedTaskReceipt {
        guard activeIdentity == nil else {
            throw DelegatedTaskSupervisorError.workerAlreadyRunning
        }

        let identity = "\(envelope.taskID):\(envelope.attemptID)"
        activeIdentity = identity
        operation = Task { [weak self] in
            let result = await AgentTaskInvocation.invoke(
                invoker,
                envelope: envelope,
                parentTurnID: parentTurnID
            )
            await completion(result)
            await self?.settle(identity: identity)
        }
        return DelegatedTaskReceipt(envelope: envelope)
    }

    func cancel() {
        operation?.cancel()
    }

    private func settle(identity: String) {
        guard activeIdentity == identity else { return }
        operation = nil
        activeIdentity = nil
    }
}

/// Binds a routed worker context to the bounded task runner.
nonisolated struct ConfiguredAgentTaskInvoker: TurnAwareAgentTaskInvoking {
    let runner: any AgentTaskRunning
    let context: AgentTaskRunContext
    let events: AgentTaskRunnerEvents
    let coordinator: AgentActivityAgent?
    let worker: AgentActivityAgent?
    let activityChanged: @Sendable (AgentActivityRuntimeEvent) async -> Void

    init(
        runner: any AgentTaskRunning,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents,
        coordinator: AgentActivityAgent? = nil,
        worker: AgentActivityAgent? = nil,
        activityChanged: @escaping @Sendable (
            AgentActivityRuntimeEvent
        ) async -> Void = { _ in }
    ) {
        self.runner = runner
        self.context = context
        self.events = events
        self.coordinator = coordinator
        self.worker = worker
        self.activityChanged = activityChanged
    }

    /// Detaches a retained worker from its parent turn's transient Activity and
    /// tool callbacks. The background harness supplies durable callbacks whose
    /// output can be routed by originating conversation after the turn ends.
    func backgroundIsolated(
        toolFinished: @escaping @Sendable (
            AgentTaskToolOutputEvent
        ) async -> Void
    ) -> Self {
        Self(
            runner: runner,
            context: context,
            events: AgentTaskRunnerEvents(toolFinished: toolFinished)
        )
    }

    @MainActor
    func invoke(_ envelope: AgentTaskEnvelope) async -> AgentTaskResult {
        return await invoke(envelope, parentTurnID: envelope.parentTurnID)
    }

    @MainActor
    func invoke(
        _ envelope: AgentTaskEnvelope,
        parentTurnID: TurnID?
    ) async -> AgentTaskResult {
        let scopedEnvelope = (try? envelope.withParentTurnID(
            parentTurnID ?? envelope.parentTurnID
        )) ?? envelope
        if let coordinator, let worker {
            await activityChanged(
                .started(
                    envelope: scopedEnvelope,
                    coordinator: coordinator,
                    worker: worker,
                    startedAt: .now
                )
            )
            await activityChanged(
                .phaseChanged(
                    taskID: scopedEnvelope.taskID,
                    attemptID: scopedEnvelope.attemptID,
                    phase: .delegating
                )
            )
            // The bounded runner owns the complete worker session, so entering
            // it is the deterministic handoff boundary.
            await activityChanged(
                .phaseChanged(
                    taskID: scopedEnvelope.taskID,
                    attemptID: scopedEnvelope.attemptID,
                    phase: .workerRunning
                )
            )
        }

        let result = await runner.run(
            envelope: scopedEnvelope,
            context: context,
            events: events
        )
        if coordinator != nil, worker != nil {
            // Every runner path returns a typed terminal result, including
            // timeout and cancellation, which also closes any active tool.
            await activityChanged(.finished(result))
        }
        return result
    }
}

/// Structured coordinator tool used by production Foundation Models profiles,
/// including DeepSeek's OpenAI-compatible transport.
struct DelegateTaskTool: Tool {
    typealias Arguments = DelegateTaskArguments
    typealias Output = String

    let invoker: any AgentTaskInvoking
    let currentTurnID: @MainActor @Sendable () async -> TurnID?
    let backgroundSubmission: DelegatedTaskBackgroundSubmission?

    init(
        invoker: any AgentTaskInvoking,
        currentTurnID: @escaping @MainActor @Sendable () async -> TurnID? = { nil },
        backgroundSubmission: DelegatedTaskBackgroundSubmission? = nil
    ) {
        self.invoker = invoker
        self.currentTurnID = currentTurnID
        self.backgroundSubmission = backgroundSubmission
    }

    var name: String { "delegate_task" }
    var description: String {
        """
        Delegate one goal to the configured worker. Use coding when the worker
        must inspect or change the workspace: it receives the complete worker
        tool bundle configured by the active profile. Use text when the worker only needs to
        return prose: it receives no tools.
        TurboCode returns either a JSON AgentTaskResult or an accepted receipt
        when background delegation is enabled. Do not wait or poll after an
        accepted receipt; the harness reports the result when the worker ends.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: DelegateTaskArguments) async throws -> String {
        let envelope = try arguments.envelope()
        let parentTurnID = await currentTurnID()
        if let backgroundSubmission {
            let receipt = try await backgroundSubmission(
                envelope,
                invoker,
                parentTurnID
            )
            return try Self.encode(receipt)
        }
        let result = await AgentTaskInvocation.invoke(
            invoker,
            envelope: envelope,
            parentTurnID: parentTurnID
        )
        return try Self.encode(result)
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentTaskWorkerError.invalidEnvelopeEncoding
        }
        return json
    }
}
