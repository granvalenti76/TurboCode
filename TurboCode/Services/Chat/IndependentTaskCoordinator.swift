import Foundation

/// Owns the explicit `/task` application command from TurnID admission through
/// worker settlement, visible receipt, transcript handoff, and persistence.
/// This is not a model tool and therefore never depends on the active profile's
/// advertised capability catalog.
@MainActor
final class IndependentTaskCoordinator {
    private let runtime: AgentRuntime
    private let runtimeProjection: AgentRuntimeProjectionStore
    private let responseCoordinator: ChatResponseCoordinator
    private let invokerFactory: AgentTaskInvokerFactory
    private let modelRuntime: ModelRuntimeStore
    private let conversations: ConversationStore
    private let timeline: ChatTimelineStore
    private let codexRuntime: CodexRuntimeStore
    private let workspace: WorkspaceStore
    private let presentation: ChatPresentationViewModel
    private let sessions: ConversationSessionCoordinator
    private let profiles: ProfileSelectionCoordinator
    private let lifecycle: ConversationLifecycleCoordinator

    init(
        runtime: AgentRuntime,
        runtimeProjection: AgentRuntimeProjectionStore,
        responseCoordinator: ChatResponseCoordinator,
        invokerFactory: AgentTaskInvokerFactory,
        modelRuntime: ModelRuntimeStore,
        conversations: ConversationStore,
        timeline: ChatTimelineStore,
        codexRuntime: CodexRuntimeStore,
        workspace: WorkspaceStore,
        presentation: ChatPresentationViewModel,
        sessions: ConversationSessionCoordinator,
        profiles: ProfileSelectionCoordinator,
        lifecycle: ConversationLifecycleCoordinator
    ) {
        self.runtime = runtime
        self.runtimeProjection = runtimeProjection
        self.responseCoordinator = responseCoordinator
        self.invokerFactory = invokerFactory
        self.modelRuntime = modelRuntime
        self.conversations = conversations
        self.timeline = timeline
        self.codexRuntime = codexRuntime
        self.workspace = workspace
        self.presentation = presentation
        self.sessions = sessions
        self.profiles = profiles
        self.lifecycle = lifecycle
    }

    func run(goal: String) async {
        guard !runtimeProjection.hasActiveOperation else { return }
        await lifecycle.ensureActiveThread()
        let command = "/task \(goal)"
        let envelope: AgentTaskEnvelope
        do {
            envelope = try DelegateTaskArguments(
                mode: DelegatedWorkerMode.coding.rawValue,
                goal: goal
            ).envelope()
        } catch {
            presentation.errorMessage = error.localizedDescription
            return
        }
        guard conversations.activeThreadID != nil else {
            presentation.errorMessage = "TurboCode could not create the conversation."
            return
        }

        let configuration = modelRuntime.makeSessionConfiguration(
            workspaceRoot: workspace.root
        )
        let invoker = invokerFactory.makeIndependentTaskInvoker(
            configuration: configuration,
            events: responseCoordinator.modelSessionEvents
        )
        presentation.errorMessage = nil
        let turnID = TurnID()
        let request = TurnRequest(
            id: turnID,
            prompt: command,
            backend: modelRuntime.activeBackend,
            modelName: modelRuntime.composerModel,
            workspaceRoot: workspace.root
        )
        guard await runtime.apply(.started(request)) else { return }
        await runtime.reserveOperationKind(.independent, for: turnID)
        _ = await runtime.apply(
            .phaseChanged(turnID: turnID, phase: .preparing, at: Date())
        )
        responseCoordinator.delegationChanged(true)
        await runtime.runOperation(
            turnID: turnID,
            operationKind: .independent
        ) { [weak self] in
            guard let self else { return }
            _ = await runtime.apply(
                .phaseChanged(turnID: turnID, phase: .streaming, at: Date())
            )
            let result = await AgentTaskInvocation.invoke(
                invoker,
                envelope: envelope,
                parentTurnID: turnID
            )
            guard !Task.isCancelled else {
                _ = await runtime.apply(
                    .completed(
                        turnID: turnID,
                        outcome: .cancelled(reason: "Independent task cancelled."),
                        at: Date()
                    )
                )
                return
            }
            _ = await runtime.apply(
                .phaseChanged(turnID: turnID, phase: .settling, at: Date())
            )
            await finish(command: command, result: result, turnID: turnID)
            _ = await runtime.apply(
                .completed(
                    turnID: turnID,
                    outcome: Self.runtimeOutcome(for: result),
                    at: Date()
                )
            )
        }
        responseCoordinator.delegationChanged(false)
    }

    private func finish(
        command: String,
        result: AgentTaskResult,
        turnID: TurnID
    ) async {
        guard TurnCompletionPolicy.accepts(
            turnID: turnID,
            activeTurnID: await runtime.ownsOperation(turnID) ? turnID : nil,
            isCancelled: Task.isCancelled
        ) else { return }
        let response = Self.render(result)
        timeline.presentTaskTurn(command: command, response: response)
        await appendToTranscript(command: command, response: response)
        if let threadID = conversations.activeThreadID {
            conversations.touchThread(id: threadID)
            if modelRuntime.activeBackend == .codex {
                await codexRuntime.captureImportedContext(
                    turboThreadID: threadID,
                    blocks: timeline.blocks
                )
            }
            await sessions.persistActiveSession(id: threadID)
        }
    }

    /// Makes the worker result available to the next Foundation Models turn
    /// without importing the worker's internal tool-call transcript.
    private func appendToTranscript(command: String, response: String) async {
        guard modelRuntime.activeBackend != .codex else { return }
        let additions = RuntimeContextHandoff.transcript(from: [
            ChatBlock(kind: .user, text: command),
            ChatBlock(kind: .assistant, text: response)
        ])
        guard let transcript = await sessions.foundationModelsTranscript() else {
            return
        }
        let existing = SessionRebuildHistory.prepare(
            transcript,
            keepingHistory: true,
            discardingCapabilityContext: false
        )
        await profiles.rebuildSession(restoringHistory: existing + additions)
    }

    nonisolated static func render(_ result: AgentTaskResult) -> String {
        var sections = ["### Independent task", result.technicalSummary]
        if let failureDetail = result.failureDetail,
           !failureDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("**Details:** \(failureDetail)")
        }
        if !result.unresolvedWork.isEmpty {
            sections.append(
                "**Remaining:**\n" + result.unresolvedWork
                    .map { "- \($0)" }
                    .joined(separator: "\n")
            )
        }
        if result.outcome == .failed || result.outcome == .cancelled {
            sections.insert("Status: `\(result.outcome.rawValue)`", at: 1)
        }
        return sections.joined(separator: "\n\n")
    }

    nonisolated static func runtimeOutcome(for result: AgentTaskResult) -> TurnOutcome {
        switch result.outcome {
        case .completed, .verified:
            .succeeded
        case .cancelled:
            .cancelled(reason: result.failureDetail)
        case .failed:
            .failed(
                TurnFailure(
                    code: result.failureReason?.rawValue ?? "task.failed",
                    message: result.failureDetail ?? result.technicalSummary
                )
            )
        }
    }
}
