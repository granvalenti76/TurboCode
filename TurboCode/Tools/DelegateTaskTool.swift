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
    let currentTurnID: @MainActor @Sendable () -> TurnID?

    init(
        invoker: any AgentTaskInvoking,
        currentTurnID: @escaping @MainActor @Sendable () -> TurnID? = { nil }
    ) {
        self.invoker = invoker
        self.currentTurnID = currentTurnID
    }

    var name: String { "delegate_task" }
    var description: String {
        """
        Delegate one goal to the configured worker. Use coding when the worker
        must inspect or change the workspace: it receives the complete worker
        tool bundle configured by the active profile. Use text when the worker only needs to
        return prose: it receives no tools.
        TurboCode returns a JSON AgentTaskResult; inspect its outcome and remain
        responsible for the final response.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: DelegateTaskArguments) async throws -> String {
        let envelope = try arguments.envelope()
        let result = await AgentTaskInvocation.invoke(
            invoker,
            envelope: envelope,
            parentTurnID: currentTurnID()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentTaskWorkerError.invalidEnvelopeEncoding
        }
        return json
    }
}
