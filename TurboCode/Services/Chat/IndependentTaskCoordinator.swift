import Foundation

nonisolated struct BackgroundToolArtifact: Sendable {
    let toolCallID: String
    let receipt: ToolReceipt
}

/// Buffers terminal worker events outside the active response lane. Their
/// typed receipts are resolved only after the worker settles, when the harness
/// can route them using the captured conversation identity.
actor BackgroundToolJournal {
    private var events: [AgentTaskToolOutputEvent] = []

    func record(_ event: AgentTaskToolOutputEvent) {
        events.append(event)
    }

    func snapshot() -> [AgentTaskToolOutputEvent] {
        events
    }
}

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
    private let background: BackgroundDelegationCoordinator

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
        lifecycle: ConversationLifecycleCoordinator,
        background: BackgroundDelegationCoordinator
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
        self.background = background
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
        if modelRuntime.agentTuning.orchestrator.runsDelegatedTasksInBackground {
            do {
                _ = try await background.submitCommandTask(
                    command: command,
                    envelope: envelope,
                    invoker: invoker
                )
            } catch {
                presentation.errorMessage = error.localizedDescription
            }
            return
        }
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
        guard let transcript = await sessions.foundationModelsCanonicalTranscript() else {
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

/// Routes detached worker settlement back into the conversation that admitted
/// it. The coordinator captures stable identity before execution and never
/// consults the currently visible workspace to decide where a result belongs.
@MainActor
final class BackgroundDelegationCoordinator {
    private enum Origin: Sendable {
        case tool
        case command(String)
    }

    private let supervisor: DelegatedTaskSupervisor
    private let runtime: AgentRuntime
    private let responseCoordinator: ChatResponseCoordinator
    private let modelRuntime: ModelRuntimeStore
    private let conversations: ConversationStore
    private let timeline: ChatTimelineStore
    private let codexRuntime: CodexRuntimeStore
    private let persistence: ConversationPersistenceService
    private let sessions: ConversationSessionCoordinator
    private let profiles: ProfileSelectionCoordinator

    init(
        supervisor: DelegatedTaskSupervisor,
        runtime: AgentRuntime,
        responseCoordinator: ChatResponseCoordinator,
        modelRuntime: ModelRuntimeStore,
        conversations: ConversationStore,
        timeline: ChatTimelineStore,
        codexRuntime: CodexRuntimeStore,
        persistence: ConversationPersistenceService,
        sessions: ConversationSessionCoordinator,
        profiles: ProfileSelectionCoordinator
    ) {
        self.supervisor = supervisor
        self.runtime = runtime
        self.responseCoordinator = responseCoordinator
        self.modelRuntime = modelRuntime
        self.conversations = conversations
        self.timeline = timeline
        self.codexRuntime = codexRuntime
        self.persistence = persistence
        self.sessions = sessions
        self.profiles = profiles
    }

    func submitToolTask(
        envelope: AgentTaskEnvelope,
        invoker: any AgentTaskInvoking,
        parentTurnID: TurnID?
    ) async throws -> DelegatedTaskReceipt {
        try await submit(
            envelope: envelope,
            invoker: invoker,
            parentTurnID: parentTurnID,
            origin: .tool
        )
    }

    func submitCommandTask(
        command: String,
        envelope: AgentTaskEnvelope,
        invoker: any AgentTaskInvoking
    ) async throws -> DelegatedTaskReceipt {
        try await submit(
            envelope: envelope,
            invoker: invoker,
            parentTurnID: nil,
            origin: .command(command)
        )
    }

    private func submit(
        envelope: AgentTaskEnvelope,
        invoker: any AgentTaskInvoking,
        parentTurnID: TurnID?,
        origin: Origin
    ) async throws -> DelegatedTaskReceipt {
        guard let threadID = conversations.activeThreadID else {
            throw DelegatedTaskSupervisorError.missingOriginatingConversation
        }
        let backend = modelRuntime.activeBackend
        let workspaceName = responseCoordinator.currentWorkspaceName
        let journal = BackgroundToolJournal()
        // Production workers are configured values, so their immutable model
        // and tool context can be retained while transient parent-turn events
        // are replaced. Test invokers have no tool event stream to isolate.
        let retainedInvoker: any AgentTaskInvoking
        if let configured = invoker as? ConfiguredAgentTaskInvoker {
            retainedInvoker = configured.backgroundIsolated { event in
                await journal.record(event)
            }
        } else {
            retainedInvoker = invoker
        }
        // Publish busy delegation before crossing to the supervisor so an
        // immediately completing fake or local worker cannot invert true/false.
        responseCoordinator.delegationChanged(true)
        let receipt = try await supervisor.submit(
            envelope: envelope,
            invoker: retainedInvoker,
            parentTurnID: parentTurnID
        ) { [weak self] result in
            await self?.finish(
                result: result,
                envelope: envelope,
                threadID: threadID,
                backend: backend,
                workspaceName: workspaceName,
                journal: journal
            )
        }
        if case .command(let command) = origin {
            let acknowledgement = Self.acknowledgement(for: receipt)
            let blocks = [
                ChatBlock(kind: .user, text: command),
                ChatBlock(kind: .assistant, text: acknowledgement)
            ]
            timeline.presentTaskTurn(
                command: command,
                response: acknowledgement
            )
            conversations.touchThread(id: threadID)
            await appendToActiveContext(
                blocks: blocks,
                threadID: threadID,
                backend: backend
            )
        }
        return receipt
    }

    private func finish(
        result: AgentTaskResult,
        envelope: AgentTaskEnvelope,
        threadID: String,
        backend: ModelBackend,
        workspaceName: String?,
        journal: BackgroundToolJournal
    ) async {
        // A tool-authored task can outlive its parent response. Waiting for the
        // conversational lane prevents rebuilding a live provider session.
        await runtime.waitUntilIdle()
        let response = IndependentTaskCoordinator.render(result)
        let visibleBlocks = [ChatBlock(kind: .assistant, text: response)]
        let artifacts = await responseCoordinator.resolveBackgroundToolArtifacts(
            await journal.snapshot(),
            workspaceName: workspaceName
        )
        let artifactBlocks = Self.blocks(for: artifacts)
        let contextBlocks = [
            ChatBlock(
                kind: .user,
                text: "Background delegated task completed: \(envelope.goal)"
            ),
            ChatBlock(kind: .assistant, text: response)
        ]

        if conversations.activeThreadID == threadID {
            responseCoordinator.presentBackgroundToolArtifacts(artifacts)
            timeline.presentTaskCompletion(visibleBlocks[0])
            conversations.touchThread(id: threadID)
            await appendToActiveContext(
                blocks: contextBlocks,
                threadID: threadID,
                backend: modelRuntime.activeBackend
            )
        } else {
            do {
                try await persistence.append(
                    id: threadID,
                    blocks: artifactBlocks + visibleBlocks,
                    transcriptEntries: backend == .codex
                        ? []
                        : RuntimeContextHandoff.transcript(from: contextBlocks)
                )
                conversations.touchThread(id: threadID)
                // Navigation can make the origin visible while the repository
                // actor is appending. Reconcile by stable block identity after
                // the active response lane settles, without duplicating a load
                // that already observed the atomic append.
                await runtime.waitUntilIdle()
                if conversations.activeThreadID == threadID,
                   !timeline.blocks.contains(where: {
                       $0.id == visibleBlocks[0].id
                   }) {
                    responseCoordinator.presentBackgroundToolArtifacts(artifacts)
                    timeline.presentTaskCompletion(visibleBlocks[0])
                    await appendToActiveContext(
                        blocks: contextBlocks,
                        threadID: threadID,
                        backend: modelRuntime.activeBackend
                    )
                }
            } catch {
                print(
                    "[TurboCode] Failed to deliver background task: \(error.localizedDescription)"
                )
            }
        }
        responseCoordinator.delegationChanged(false)
    }

    private func appendToActiveContext(
        blocks: [ChatBlock],
        threadID: String,
        backend: ModelBackend
    ) async {
        if backend == .codex {
            await codexRuntime.captureImportedContext(
                turboThreadID: threadID,
                blocks: timeline.blocks
            )
        } else if let transcript = await sessions.foundationModelsCanonicalTranscript() {
            let existing = SessionRebuildHistory.prepare(
                transcript,
                keepingHistory: true,
                discardingCapabilityContext: false
            )
            await profiles.rebuildSession(
                restoringHistory: existing
                    + RuntimeContextHandoff.transcript(from: blocks)
            )
        }
        await sessions.persistActiveSession(id: threadID)
    }

    private nonisolated static func acknowledgement(
        for receipt: DelegatedTaskReceipt
    ) -> String {
        "Background task accepted (`\(receipt.taskID)`). TurboCode will report the result when the worker finishes."
    }

    /// Converts immutable receipts into the same durable blocks used by live
    /// presentation. Repository-only invalidations intentionally have no row;
    /// the workspace is refreshed when its conversation becomes active.
    private nonisolated static func blocks(
        for artifacts: [BackgroundToolArtifact]
    ) -> [ChatBlock] {
        artifacts.compactMap { artifact in
            switch artifact.receipt {
            case .workspaceListing(let listing):
                ChatBlock(
                    id: "workspace-listing-\(artifact.toolCallID)",
                    kind: .workspaceListing,
                    text: listing.path,
                    workspaceListing: listing
                )
            case .pluginWidget(let widget):
                ChatBlock(
                    id: "plugin-widget-\(artifact.toolCallID)",
                    kind: .pluginWidget,
                    text: widget.title,
                    pluginWidget: widget
                )
            case .diffPatch(let receipt):
                ChatBlock(
                    id: receipt.transactionID,
                    kind: .diffPatch,
                    text: "",
                    diffPatch: receipt.block
                )
            case .gitStatus(let status):
                ChatBlock(kind: .gitStatus, text: "", gitStatus: status)
            case .gitCommit(let commit):
                ChatBlock(kind: .gitCommit, text: "", gitCommit: commit)
            case .repositoryChanged:
                nil
            }
        }
    }
}
