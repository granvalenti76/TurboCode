import Foundation
import FoundationModels

// MARK: - Call Powerful Model Tool

/// Arguments for delegating a task to the powerful model.
@Generable
struct CallPowerfulModelArguments {
    /// The full task, question, or problem description to delegate.
    /// Include all necessary context so the powerful model can work independently.
    var task: String
}

/// A tool that lets the Apple on-device model delegate a task to a powerful
/// remote model via a `ChatCompletionsLanguageModel` (OpenAI-compatible API).
///
/// This remains the compatibility surface for the on-device orchestrator. Its
/// free-text argument is converted immediately into the same structured task
/// contract used by future coordinator adapters.
struct CallPowerfulModelTool: Tool {
    typealias Arguments = CallPowerfulModelArguments
    typealias Output = String

    var name: String { "call_powerful_model" }
    var description: String {
        """
        Delegate a complex or resource-intensive task to a more capable AI model.
        Use this tool when the user's request requires deep reasoning, large code
        generation, multi-step analysis, or detailed research — anything that
        benefits from a larger, more powerful model.

        Provide a **self-contained task description** with all the context the
        other model needs (relevant code snippets, error messages, requirements).
        Do **not** include conversation history or meta-instructions — just the
        concrete problem.

        After receiving the response, synthesise it into a clear final answer
        for the user, preserving important details, code blocks, and explanations.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    private let model: any LanguageModel
    private let temperature: Double?
    private let reasoningLevel: ContextOptions.ReasoningLevel?
    /// Tools registered with the delegate session (e.g. read_file, ripgrep, file_system).
    private let delegateTools: [any Tool]
    /// System instructions for the delegate session (workspace context, rules, etc.).
    private let delegateInstructions: String
    private let onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)?
    private let onToolEnd: (@Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void)?
    private let runner: any AgentTaskRunning
    private let coordinator: AgentActivityAgent?
    private let worker: AgentActivityAgent?
    private let activityChanged: @Sendable (
        AgentActivityRuntimeEvent
    ) async -> Void

    init(
        model: any LanguageModel,
        temperature: Double?,
        reasoningLevel: ContextOptions.ReasoningLevel?,
        delegateTools: [any Tool],
        delegateInstructions: String,
        onToolStart: (@Sendable (Transcript.ToolCall) async -> Void)? = nil,
        onToolEnd: (@Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void)? = nil,
        runner: any AgentTaskRunning = BoundedAgentTaskRunner(),
        coordinator: AgentActivityAgent? = nil,
        worker: AgentActivityAgent? = nil,
        activityChanged: @escaping @Sendable (
            AgentActivityRuntimeEvent
        ) async -> Void = { _ in }
    ) {
        self.model = model
        self.temperature = temperature
        self.reasoningLevel = reasoningLevel
        self.delegateTools = delegateTools
        self.delegateInstructions = delegateInstructions
        self.onToolStart = onToolStart
        self.onToolEnd = onToolEnd
        self.runner = runner
        self.coordinator = coordinator
        self.worker = worker
        self.activityChanged = activityChanged
    }

    func call(arguments: CallPowerfulModelArguments) async throws -> String {
        return try await Task { @MainActor in
            let taskID = UUID().uuidString
            let envelope = try AgentTaskEnvelope(
                taskID: taskID,
                attemptID: UUID().uuidString,
                mode: .coding,
                goal: arguments.task,
                acceptanceCriteria: [
                    "Return a complete, technically actionable response to the delegated task."
                ],
                budget: .default
            )
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
                context: AgentTaskRunContext(
                    model: model,
                    tools: delegateTools,
                    instructions: delegateInstructions,
                    temperature: temperature,
                    reasoningLevel: reasoningLevel
                ),
                events: AgentTaskRunnerEvents(
                    toolStarted: { event in
                        await activityChanged(
                            .toolStarted(
                                taskID: event.taskID,
                                attemptID: event.attemptID,
                                tool: AgentActivityRuntimeMapping.tool(
                                    from: event.call,
                                    owner: .worker
                                )
                            )
                        )
                        if let onToolStart {
                            await onToolStart(event.call)
                        }
                    },
                    toolFinished: { event in
                        await activityChanged(
                            .toolFinished(
                                taskID: event.taskID,
                                attemptID: event.attemptID,
                                callID: event.call.id
                            )
                        )
                        if let onToolEnd {
                            await onToolEnd(event.call, event.output)
                        }
                    },
                    verificationStarted: { taskID, attemptID, _ in
                        await activityChanged(
                            .phaseChanged(
                                taskID: taskID,
                                attemptID: attemptID,
                                phase: .verifying
                            )
                        )
                    }
                )
            )
            if coordinator != nil, worker != nil {
                await activityChanged(.finished(result))
            }
            return result.technicalSummary
        }.value
    }
}
