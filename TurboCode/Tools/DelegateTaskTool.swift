import Foundation
import FoundationModels

/// Flat provider-facing arguments for the structured delegation contract.
///
/// Keeping the schema flat makes it portable between Foundation Models dynamic
/// profiles and Codex App Server dynamic tools without provider-only fields.
@Generable
struct DelegateTaskArguments {
    /// Stable identifier shared by every attempt for this logical task.
    var taskID: String
    /// Unique identifier for this execution attempt.
    var attemptID: String
    /// Coarse worker mode: coding gets the default tool bundle, text gets none.
    @Guide(.anyOf(["coding", "text"]))
    var mode: String = "coding"
    /// Concrete outcome the worker must produce.
    var goal: String
    /// Observable conditions the worker should satisfy.
    var acceptanceCriteria: [String]
    /// Workspace-relative files or directories likely relevant to the task.
    var suggestedScope: [String]
    /// Deterministic verification requested after the worker: none, build, or test.
    @Guide(.anyOf(["none", "build", "test"]))
    var verificationRequest: String
    /// Optional workspace-relative .xcworkspace or .xcodeproj for verification.
    var verificationContainerPath: String? = nil
    /// Optional scheme retained for deterministic build or test verification.
    var verificationScheme: String? = nil
    /// Optional build configuration, such as Debug or Release.
    var verificationConfiguration: String? = nil
    /// Optional xcodebuild destination, such as platform=macOS.
    var verificationDestination: String? = nil
    /// Wall-clock limit applied by TurboCode, in seconds.
    var timeoutSeconds: Int
    /// Maximum number of worker tool calls.
    var maximumToolCalls: Int

    func envelope() throws -> AgentTaskEnvelope {
        guard let workerMode = DelegatedWorkerMode(rawValue: mode) else {
            throw DelegateTaskAdapterError.unknownMode(mode)
        }
        guard let verification = VerificationRequest(rawValue: verificationRequest) else {
            throw DelegateTaskAdapterError.unknownVerification(verificationRequest)
        }
        let verificationParameters: AgentVerificationParameters? =
            if [
                verificationContainerPath,
                verificationScheme,
                verificationConfiguration,
                verificationDestination
            ].contains(where: { $0 != nil }) {
                AgentVerificationParameters(
                    containerPath: verificationContainerPath,
                    scheme: verificationScheme,
                    configuration: verificationConfiguration,
                    destination: verificationDestination
                )
            } else {
                nil
            }
        return try AgentTaskEnvelope(
            taskID: taskID,
            attemptID: attemptID,
            mode: workerMode,
            goal: goal,
            acceptanceCriteria: acceptanceCriteria,
            suggestedScope: suggestedScope,
            verificationRequest: verification,
            verificationParameters: verificationParameters,
            budget: DelegationBudget(
                timeoutSeconds: timeoutSeconds,
                maximumToolCalls: maximumToolCalls
            )
        )
    }
}

nonisolated enum DelegateTaskAdapterError: LocalizedError, Sendable, Equatable {
    case unknownMode(String)
    case unknownVerification(String)

    var errorDescription: String? {
        switch self {
        case .unknownMode(let mode):
            "Unknown delegated worker mode '\(mode)'."
        case .unknownVerification(let value):
            "Unknown verification request '\(value)'."
        }
    }
}

/// Provider-neutral worker invocation used by both coordinator adapters.
nonisolated protocol AgentTaskInvoking: Sendable {
    @MainActor
    func invoke(_ envelope: AgentTaskEnvelope) async -> AgentTaskResult
}

/// Binds a routed worker context to the bounded task runner.
nonisolated struct ConfiguredAgentTaskInvoker: AgentTaskInvoking {
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
        if let coordinator, let worker {
            await activityChanged(
                .started(
                    envelope: envelope,
                    coordinator: coordinator,
                    worker: worker,
                    startedAt: .now
                )
            )
            await activityChanged(
                .phaseChanged(
                    taskID: envelope.taskID,
                    attemptID: envelope.attemptID,
                    phase: .delegating
                )
            )
            // The bounded runner owns the complete worker session, so entering
            // it is the deterministic handoff boundary.
            await activityChanged(
                .phaseChanged(
                    taskID: envelope.taskID,
                    attemptID: envelope.attemptID,
                    phase: .workerRunning
                )
            )
        }

        let result = await runner.run(
            envelope: envelope,
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

    var name: String { "delegate_task" }
    var description: String {
        """
        Delegate one bounded task to the configured worker. Supply stable task
        and attempt identifiers, a worker mode (coding or text), explicit
        acceptance criteria, a narrow scope, verification, and a hard budget.
        Coding workers receive TurboCode's complete default tool bundle; text
        workers receive no tools.
        TurboCode returns a JSON AgentTaskResult; inspect its outcome and remain
        responsible for verification and the final response.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: DelegateTaskArguments) async throws -> String {
        let envelope = try arguments.envelope()
        let result = await invoker.invoke(envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentTaskWorkerError.invalidEnvelopeEncoding
        }
        return json
    }
}
