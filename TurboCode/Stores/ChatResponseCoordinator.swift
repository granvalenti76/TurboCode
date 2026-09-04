import Foundation
import FoundationModels
import Observation

/// Coordinates one response lifecycle across a runtime and the chat timeline.
///
/// Provider loops remain in their dedicated runners. This coordinator maps
/// their outcomes into timeline blocks and tool presentation state; it does not
/// own conversation persistence, model selection, or workbench navigation.
@MainActor
@Observable
final class ChatResponseCoordinator {
    nonisolated struct InterruptedNativeTurn: Sendable {
        let prompt: String
        let reasoning: String
        let assistantText: String
    }

    nonisolated struct Result: Sendable {
        let errorMessage: String?
        let touchedConversation: Bool
        let interruptedNativeTurn: InterruptedNativeTurn?

        init(
            errorMessage: String?,
            touchedConversation: Bool,
            interruptedNativeTurn: InterruptedNativeTurn? = nil
        ) {
            self.errorMessage = errorMessage
            self.touchedConversation = touchedConversation
            self.interruptedNativeTurn = interruptedNativeTurn
        }
    }

    /// Closes the current Codex response segment before `turn/steer` is sent;
    /// cumulative provider text is then rendered only in the new segment.
    @discardableResult
    func beginSteeringSegment(
        turnID: TurnID,
        displayText: String,
        metadata: SteeringDeliveryMetadata,
        model: String
    ) -> Bool {
        presenter.beginSteeringSegment(
            turnID: turnID,
            displayText: displayText,
            metadata: metadata,
            model: model
        )
    }

    /// Captures ownership when the provider starts a native tool. Looking up
    /// the current turn again at completion could mislabel a delayed callback
    /// after cancellation, restore, or a subsequent submission.
    private struct NativeToolInvocation {
        let turnID: TurnID
        let startedAt: Date
    }

    private let toolInteractions: ToolInteractionStore
    private let agentActivity: AgentActivityStore
    private let agentRuntime: AgentRuntime
    private let receiptRegistry: ToolReceiptRegistry
    private let presenter: ChatResponsePresenter
    private let diagnostics: ResponseDiagnostics
    /// Concrete backend adapters are constructed and executed behind this
    /// non-observable boundary. The coordinator supplies presentation output
    /// ports but never receives or retains the provider session itself.
    private let llmRuntime: LLMRuntime
    private let workspaceNameProvider: @MainActor @Sendable () -> String?
    private let activityPresentationRequested: @MainActor @Sendable () -> Void
    private var backgroundTaskSubmission: DelegatedTaskBackgroundSubmission?

    private(set) var isDelegating = false
    private(set) var activeEditGroupID: String?
    private var productGuidePresentation: ProductGuideBlock?
    private var completedRootWrite: String?
    private var pendingCoordinatorTool: AgentActivityTool?
    private var nativeToolInvocations: [String: NativeToolInvocation] = [:]
    init(
        timeline: ChatTimelineStore,
        toolInteractions: ToolInteractionStore,
        agentActivity: AgentActivityStore,
        agentRuntime: AgentRuntime = AgentRuntime(),
        llmRuntime: LLMRuntime,
        receiptRegistry: ToolReceiptRegistry = ToolReceiptRegistry(),
        reviewCoordinator: ReviewCoordinator? = nil,
        workspaceNameProvider: @escaping @MainActor @Sendable () -> String? = { nil },
        activityPresentationRequested: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.toolInteractions = toolInteractions
        self.agentActivity = agentActivity
        self.agentRuntime = agentRuntime
        self.llmRuntime = llmRuntime
        self.receiptRegistry = receiptRegistry
        self.presenter = ChatResponsePresenter(
            timeline: timeline,
            reviewCoordinator: reviewCoordinator
        )
        self.diagnostics = ResponseDiagnostics()
        self.workspaceNameProvider = workspaceNameProvider
        self.activityPresentationRequested = activityPresentationRequested
    }

    /// Provider sessions use this router for tool, delegation, and Activity
    /// callbacks. Keeping construction here prevents the UI facade from
    /// becoming the owner of provider stream closures; the injected closures
    /// are presentation requests, not provider lifecycle ownership.
    var modelSessionEvents: ModelSessionEvents {
        ModelSessionEvents(
            currentTurnID: { [weak self] in
                await self?.currentTurnState()?.id
            },
            toolReceiptRegistry: receiptRegistry,
            toolStarted: { [weak self] call, backend, owner in
                await self?.toolStarted(
                    call,
                    backend: backend,
                    owner: owner
                )
            },
            toolFinished: { [weak self] call, output, backend, owner in
                guard let self else { return }
                let workspaceName = await MainActor.run {
                    self.workspaceNameProvider()
                }
                await self.toolFinished(
                    call,
                    output: output,
                    backend: backend,
                    owner: owner,
                    workspaceName: workspaceName
                )
            },
            delegationChanged: { [weak self] isDelegating in
                await MainActor.run {
                    self?.delegationChanged(isDelegating)
                }
            },
            agentActivityChanged: { [weak self] event in
                await MainActor.run {
                    self?.agentActivityChanged(event)
                }
            },
            backgroundTaskSubmission: backgroundTaskSubmission
        )
    }

    /// Assembly installs the background route after profile construction has
    /// closed its dependency cycle with this response coordinator.
    func setBackgroundTaskSubmission(
        _ submission: @escaping DelegatedTaskBackgroundSubmission
    ) {
        backgroundTaskSubmission = submission
    }

    var currentWorkspaceName: String? {
        workspaceNameProvider()
    }

    /// Resolves receipts against the registry captured by the worker tools,
    /// without admitting them through a conversational TurnID that has already
    /// settled. Presentation remains a separate origin-thread decision.
    func resolveBackgroundToolArtifacts(
        _ events: [AgentTaskToolOutputEvent],
        workspaceName: String?
    ) async -> [BackgroundToolArtifact] {
        var artifacts: [BackgroundToolArtifact] = []
        for event in events {
            let resolution = await ToolReceiptRouter.resolve(
                for: event.call,
                output: event.output,
                registry: receiptRegistry,
                workspaceName: workspaceName
            )
            if let receipt = resolution.receipt {
                artifacts.append(
                    BackgroundToolArtifact(
                        toolCallID: event.call.id,
                        receipt: receipt
                    )
                )
            }
        }
        return artifacts
    }

    func presentBackgroundToolArtifacts(
        _ artifacts: [BackgroundToolArtifact]
    ) {
        for artifact in artifacts {
            presenter.present(
                artifact.receipt,
                toolCallID: artifact.toolCallID,
                editGroupID: nil
            )
        }
    }

    /// Keeps the runtime identity at the coordinator boundary while the
    /// existing provider runners remain unchanged. A later callback may still
    /// arrive after cancellation, so presentation code can reject it by ID.
    func ownsTurn(_ turnID: TurnID) async -> Bool {
        await agentRuntime.owns(turnID)
    }

    private func currentTurnState() async -> TurnState? {
        await agentRuntime.currentTurnState
    }

    private func beginTurn(_ request: TurnRequest) async {
        guard await acceptRuntimeEvent(.started(request)) else { return }
        nativeToolInvocations.removeAll(keepingCapacity: true)
        _ = await advanceTurn(to: .preparing, turnID: request.id)
    }

    @discardableResult
    private func advanceTurn(to phase: TurnPhase, turnID: TurnID) async -> Bool {
        await acceptRuntimeEvent(
            .phaseChanged(turnID: turnID, phase: phase, at: Date())
        )
    }

    private func finishTurn(
        _ outcome: TurnOutcome,
        turnID: TurnID
    ) async {
        _ = await acceptRuntimeEvent(
            .completed(turnID: turnID, outcome: outcome, at: Date())
        )
        nativeToolInvocations.removeAll(keepingCapacity: true)
    }

    /// Accepts lifecycle and ownership changes before any event reaches a UI
    /// projection. The actor publishes changed snapshots through its output
    /// port; content-only events still pass the TurnID gate without invalidating
    /// presentation state on every streamed token.
    @discardableResult
    private func acceptRuntimeEvent(_ event: AgentRuntimeEvent) async -> Bool {
        await agentRuntime.apply(event)
    }

    /// Backend completion is settled after the coordinator has finalized its
    /// timeline and diagnostics. Every nonterminal event is reduced immediately
    /// so stale content, tool, and approval callbacks are rejected uniformly.
    /// A redundant phase is not a reason to drop a current tool payload: native
    /// widgets remain presentation projections, independent of reducer idempotency.
    func acceptBackendEvent(_ event: AgentRuntimeEvent) async -> Bool {
        guard await ownsTurn(event.turnID) else { return false }
        if case .completed = event {
            return true
        }
        _ = await acceptRuntimeEvent(event)
        // Rich output is projected only after the owning TurnID passes the
        // runtime gate. Native and Codex adapters therefore share one receipt
        // path and stale callbacks cannot insert widgets into a newer thread.
        if case .toolFinished(let result) = event,
           let receipt = result.receipt {
            presenter.present(
                receipt,
                toolCallID: result.id,
                editGroupID: activeEditGroupID
            )
        }
        return true
    }

    /// Carries profile-owned Codex choices across the timeline boundary while
    /// leaving provider selection and persistence in their owning stores.
    func performCodex(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool,
        turnID: TurnID,
        turboThreadID: String,
        workspaceRoot: String,
        workspaceName: String?,
        mode: OrchestratorMode,
        workspaceKind: String,
        agentTuning: AgentTuningConfig,
        availableSkills: [TurboCodeSkillDefinition],
        pluginTools: [TypeScriptPluginToolBinding] = [],
        codexModelID: String?,
        codexReasoningEffort: CodexReasoningEffort?,
        delegationInvoker: (any AgentTaskInvoking)?,
        modelName: String
    ) async -> Result {
        let placeholderID = UUID().uuidString
        await beginTurn(
            TurnRequest(
                id: turnID,
                prompt: promptText,
                backend: .codex,
                modelName: modelName,
                workspaceRoot: workspaceRoot
            )
        )
        _ = await advanceTurn(to: .streaming, turnID: turnID)
        presenter.beginResponse(
            displayText: visibleInTimeline ? displayText : nil,
            placeholderID: placeholderID,
            model: modelName,
            turnID: turnID
        )
        let diagnosticsCapture = await diagnostics.beginCodexRun(
            mode: mode,
            workspaceKind: workspaceKind,
            promptCharacters: promptText.count
        )
        var result = Result(errorMessage: nil, touchedConversation: false)
        let ingress = BackendEventIngress(
            turnID: turnID,
            runtime: agentRuntime,
            delivery: { [weak self] event in
                guard let self else { return }
                switch event {
                case .assistantTextChanged(_, let text):
                    diagnosticsCapture.recordCodexText(text) {
                        self.presenter.publishAssistant(text, turnID: turnID)
                    }
                case .reasoningTextChanged(_, let text):
                    diagnosticsCapture.recordCodexText(text) {
                        self.presenter.publishReasoning(text, turnID: turnID)
                    }
                case .toolStarted(let call):
                    diagnosticsCapture.toolStarted(call)
                case .toolFinished(let toolResult):
                    diagnosticsCapture.toolFinished(toolResult)
                    if let receipt = toolResult.receipt {
                        self.presenter.present(
                            receipt,
                            toolCallID: toolResult.id,
                            editGroupID: self.activeEditGroupID
                        )
                    }
                default:
                    break
                }
            }
        )

        let backendResult = await llmRuntime.executeCodex(
            request: TurnRequest(
                id: turnID,
                prompt: promptText,
                backend: .codex,
                modelName: modelName,
                workspaceRoot: workspaceRoot
            ),
            configuration: CodexLLMExecutionConfiguration(
                turboThreadID: turboThreadID,
                workspaceName: workspaceName,
                agentTuning: agentTuning,
                availableSkills: availableSkills,
                pluginTools: agentTuning.experimental.thirdPartyPluginsEnabled
                    ? pluginTools
                    : [],
                modelID: codexModelID,
                reasoningEffort: codexReasoningEffort,
                delegationInvoker: delegationInvoker,
                backgroundTaskSubmission: agentTuning.orchestrator
                    .runsDelegatedTasksInBackground
                    ? backgroundTaskSubmission
                    : nil,
                activityStarted: { [weak self] call, summary in
                    guard let self, await self.ownsTurn(turnID) else { return }
                    self.toolInteractions.beginActivity(
                        id: call.callID,
                        toolName: call.tool,
                        summary: self.routedToolSummary(
                            summary,
                            toolName: call.tool,
                            owner: .coordinator
                        )
                    )
                    self.coordinatorToolStarted(
                        AgentActivityRuntimeMapping.tool(
                            from: call,
                            owner: .coordinator
                        )
                    )
                },
                activityEnded: { [weak self] id in
                    guard let self, await self.ownsTurn(turnID) else { return }
                    self.toolInteractions.endActivity(id: id)
                    self.coordinatorToolFinished(callID: id)
                },
                approvalRequested: { [weak self] request in
                    guard let self, await self.ownsTurn(turnID) else { return }
                    _ = await self.acceptRuntimeEvent(
                        .approvalRequested(
                            Self.runtimeApproval(from: request, turnID: turnID)
                        )
                    )
                    self.toolInteractions.enqueueApproval(request)
                }
            ),
            events: BackendSessionEvents { event in
                await ingress.receive(event)
            }
        )
        await ingress.close()

        let settlementStartedAt = Date()

        await diagnostics.finishCodex(
            capture: diagnosticsCapture,
            outcome: backendResult.outcome
        )

        guard await ownsTurn(turnID) else {
            await diagnostics.recordBoundaries(
                backend: .codex,
                settlementStartedAt: settlementStartedAt,
                capture: diagnosticsCapture
            )
            return Result(errorMessage: nil, touchedConversation: false)
        }
        let outputPlaceholderID = presenter.placeholderID(
            for: turnID,
            fallback: placeholderID
        )
        switch backendResult.outcome {
        case .succeeded:
            let assistantText = presenter.segmentedAssistantText(
                backendResult.assistantText,
                turnID: turnID
            )
            let reasoningText = presenter.segmentedReasoningText(
                backendResult.reasoningText,
                turnID: turnID
            )
            let assistantBlock = assistantText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? nil : ChatBlock(
                id: outputPlaceholderID,
                kind: .assistant,
                text: assistantText,
                model: modelName
            )
            let reasoningBlock =
                !reasoningText.isEmpty && !assistantText.isEmpty
                ? ChatBlock(
                    kind: .reasoning,
                    text: reasoningText,
                    model: modelName
                )
                : nil
            presenter.finalizeResponse(
                placeholderID: outputPlaceholderID,
                assistantBlock: assistantBlock,
                reasoningBlock: reasoningBlock
            )
            _ = await advanceTurn(to: .settling, turnID: turnID)
            await finishTurn(.succeeded, turnID: turnID)
            result = Result(errorMessage: nil, touchedConversation: true)
        case .cancelled:
            let partialText = backendResult.assistantText.isEmpty
                ? backendResult.reasoningText
                : backendResult.assistantText
            presenter.replaceResponse(
                placeholderID: outputPlaceholderID,
                block: ChatBlock(
                    id: outputPlaceholderID,
                    kind: .assistant,
                    text: partialText.isEmpty
                        ? "Response interrupted."
                        : partialText,
                    model: modelName
                )
            )
            await finishTurn(.cancelled(reason: "The turn was interrupted."), turnID: turnID)
        case .failed(let failure) where failure.code == "codex.authentication":
            presenter.replaceResponse(
                placeholderID: outputPlaceholderID,
                block: ChatBlock(
                    id: outputPlaceholderID,
                    kind: .assistant,
                    text: "Sign in with ChatGPT to continue with Codex.",
                    model: modelName
                )
            )
            await finishTurn(
                .failed(
                    TurnFailure(
                        code: "codex.authentication",
                        message: "Codex authentication is required.",
                        isRecoverable: true
                    )
                ),
                turnID: turnID
            )
        case .failed(let failure):
            presenter.replaceResponse(
                placeholderID: outputPlaceholderID,
                block: ChatBlock(
                    id: outputPlaceholderID,
                    kind: .assistant,
                    text: "Error: \(failure.message)",
                    model: modelName
                )
            )
            result = Result(
                errorMessage: failure.message,
                touchedConversation: false
            )
            await finishTurn(
                .failed(
                    TurnFailure(
                        code: "codex.request",
                        message: failure.message
                    )
                ),
                turnID: turnID
            )
        }

        let settledTurnID = await currentTurnState()?.id
        guard await ownsTurn(turnID) || settledTurnID == turnID else {
            return Result(errorMessage: nil, touchedConversation: false)
        }
        presenter.finishResponse(
            placeholderID: outputPlaceholderID
        )
        toolInteractions.clearActivities()
        await diagnostics.recordBoundaries(
            backend: .codex,
            settlementStartedAt: settlementStartedAt,
            capture: diagnosticsCapture
        )
        return result
    }

    func performNative(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool,
        turnID: TurnID,
        blocks: [ChatBlock],
        backend: ModelBackend,
        mode: OrchestratorMode,
        workspaceKind: String,
        workspaceRoot: String,
        modelName: String,
        serverURL: String? = nil,
        contextChanged: @escaping @MainActor @Sendable (LlamaContextUsage?) -> Void = { _ in }
    ) async -> Result {
        let modelPrompt = WorkspaceListingFollowUpContext.enriching(
            promptText,
            blocks: blocks
        )
        let editGroupID = UUID().uuidString
        activeEditGroupID = editGroupID
        let placeholderID = UUID().uuidString
        await beginTurn(
            TurnRequest(
                id: turnID,
                prompt: promptText,
                backend: backend,
                modelName: modelName,
                workspaceRoot: workspaceRoot
            )
        )
        presenter.beginResponse(
            displayText: visibleInTimeline ? displayText : nil,
            placeholderID: placeholderID,
            model: modelName,
            turnID: turnID
        )
        productGuidePresentation = nil
        completedRootWrite = nil
        let diagnosticsCapture = diagnostics.makePublicationCapture()
        let ingress = BackendEventIngress(
            turnID: turnID,
            runtime: agentRuntime,
            delivery: { [weak self] event in
                guard let self else { return }
                switch event {
                case .assistantTextChanged(_, let content):
                    diagnosticsCapture.recordPublication {
                        self.presenter.publishAssistant(
                            Self.userVisibleAssistantText(content),
                            turnID: turnID
                        )
                    }
                case .reasoningTextChanged(_, let reasoning):
                    diagnosticsCapture.recordPublication {
                        self.presenter.publishReasoning(
                            reasoning,
                            turnID: turnID
                        )
                    }
                case .toolFinished(let toolResult):
                    if let receipt = toolResult.receipt {
                        self.presenter.present(
                            receipt,
                            toolCallID: toolResult.id,
                            editGroupID: self.activeEditGroupID
                        )
                    }
                default:
                    break
                }
            }
        )

        let backendResult = await llmRuntime.executeNative(
            request: TurnRequest(
                id: turnID,
                prompt: modelPrompt,
                backend: backend,
                modelName: modelName,
                workspaceRoot: workspaceRoot
            ),
            configuration: NativeLLMExecutionConfiguration(
                mode: mode,
                workspaceKind: workspaceKind,
                serverURL: serverURL,
                diagnosticsChanged: { [weak self] runID in
                    guard let self, await self.ownsTurn(turnID) else { return }
                    self.diagnostics.activateRun(runID)
                },
                contextChanged: { [weak self] usage in
                    guard let self, await self.ownsTurn(turnID) else { return }
                    contextChanged(usage)
                },
                approvalRequested: { [weak self] request in
                    guard let self, await self.ownsTurn(turnID) else { return }
                    _ = await self.acceptRuntimeEvent(
                        .approvalRequested(
                            Self.runtimeApproval(from: request, turnID: turnID)
                        )
                    )
                    self.toolInteractions.enqueueApproval(request)
                }
            ),
            events: BackendSessionEvents { event in
                await ingress.receive(event)
            }
        )
        await ingress.close()
        let settlementStartedAt = Date()
        _ = await advanceTurn(to: .streaming, turnID: turnID)
        isDelegating = false
        guard await ownsTurn(turnID) else {
            await diagnostics.recordBoundaries(
                backend: backend,
                settlementStartedAt: settlementStartedAt,
                capture: diagnosticsCapture
            )
            return Result(errorMessage: nil, touchedConversation: false)
        }
        toolInteractions.clearActivities()
        var result = Result(errorMessage: nil, touchedConversation: false)

        switch backendResult.outcome {
        case .succeeded:
            let content = backendResult.assistantText
            let reasoning = backendResult.reasoningText
            let rawFinalText = content.isEmpty
                ? reasoning
                : Self.userVisibleAssistantText(content)
            let finalText = NativeToolEchoFilter.filtering(
                rawFinalText,
                workspaceListings: presenter.workspaceListings
            )
            let assistantBlock = finalText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? nil : ChatBlock(
                id: placeholderID,
                kind: productGuidePresentation == nil
                    ? .assistant
                    : .productGuide,
                text: finalText,
                model: modelName,
                productGuide: productGuidePresentation
            )
            let reasoningBlock = !reasoning.isEmpty && !content.isEmpty
                ? ChatBlock(
                    kind: .reasoning,
                    text: reasoning,
                    model: modelName
                )
                : nil
            presenter.finalizeResponse(
                placeholderID: placeholderID,
                assistantBlock: assistantBlock,
                reasoningBlock: reasoningBlock
            )
            _ = await advanceTurn(to: .settling, turnID: turnID)
            await finishTurn(.succeeded, turnID: turnID)
            result = Result(errorMessage: nil, touchedConversation: true)
        case .failed(let failure) where failure.code == "native.repetitiveOutput":
            let stoppedText = completedRootWrite.map { "Created `\($0)`." }
                ?? "Response stopped because the on-device model began repeating output. Please retry."
            presenter.replaceResponse(
                placeholderID: placeholderID,
                block: ChatBlock(
                    id: placeholderID,
                    kind: .assistant,
                    text: stoppedText,
                    model: modelName
                )
            )
            await finishTurn(
                .failed(
                    TurnFailure(
                        code: "model.repetitiveOutput",
                        message: stoppedText,
                        isRecoverable: true
                    )
                ),
                turnID: turnID
            )
        case .cancelled:
            let content = backendResult.assistantText
            let reasoning = backendResult.reasoningText
            let visibleContent = Self.userVisibleAssistantText(content)
            let assistantBlock = ChatBlock(
                id: placeholderID,
                kind: .assistant,
                text: visibleContent.isEmpty
                    ? "Response interrupted."
                    : visibleContent,
                model: modelName
            )
            let reasoningBlock = reasoning.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? nil : ChatBlock(
                kind: .reasoning,
                text: reasoning,
                model: modelName
            )
            // A cancelled provider turn is still part of the conversation.
            // Keep reasoning and visible output as distinct blocks so session
            // reconciliation can preserve the same semantic boundary.
            presenter.finalizeResponse(
                placeholderID: placeholderID,
                assistantBlock: assistantBlock,
                reasoningBlock: reasoningBlock
            )
            result = Result(
                errorMessage: nil,
                touchedConversation: false,
                interruptedNativeTurn: InterruptedNativeTurn(
                    prompt: modelPrompt,
                    reasoning: reasoning,
                    assistantText: content
                )
            )
            await finishTurn(
                .cancelled(reason: "The turn was interrupted."),
                turnID: turnID
            )
        case .failed(let failure):
            let message = failure.message
            presenter.replaceResponse(
                placeholderID: placeholderID,
                block: ChatBlock(
                    id: placeholderID,
                    kind: .assistant,
                    text: "Error: \(message)",
                    model: modelName
                )
            )
            result = Result(
                errorMessage: message,
                touchedConversation: false
            )
            await finishTurn(
                .failed(TurnFailure(code: "provider.request", message: message)),
                turnID: turnID
            )
        }

        presenter.resetLiveResponse()
        if activeEditGroupID == editGroupID {
            activeEditGroupID = nil
        }
        presenter.finishResponse(placeholderID: placeholderID)
        presenter.clearEditGroup(editGroupID)
        await diagnostics.recordBoundaries(
            backend: backend,
            settlementStartedAt: settlementStartedAt,
            capture: diagnosticsCapture
        )
        return result
    }

    func toolStarted(
        _ call: Transcript.ToolCall,
        backend: ModelBackend,
        owner: AgentActivityToolOwner
    ) async {
        guard let turnID = await currentTurnState()?.id else { return }
        let startedAt = Date()
        guard await ownsTurn(turnID) else { return }
        _ = await acceptRuntimeEvent(
            .toolStarted(
                ToolCall(
                    id: call.id,
                    turnID: turnID,
                    name: call.toolName,
                    startedAt: startedAt
                )
            )
        )
        nativeToolInvocations[call.id] = NativeToolInvocation(
            turnID: turnID,
            startedAt: startedAt
        )
        await diagnostics.toolStarted(call, backend: backend)
        if owner == .coordinator {
            coordinatorToolStarted(
                AgentActivityRuntimeMapping.tool(from: call, owner: owner)
            )
        }
        // Every provider tool gets one transient live affordance. Native
        // receipts and edit widgets still own the completed detail; this
        // activity only answers the immediate question: what is running now?
        toolInteractions.beginActivity(
            id: call.id,
            toolName: call.toolName,
            summary: routedToolSummary(
                Self.toolSummary(for: call),
                toolName: call.toolName,
                owner: owner
            )
        )
    }

    func toolFinished(
        _ call: Transcript.ToolCall,
        output: Transcript.ToolOutput,
        backend: ModelBackend,
        owner: AgentActivityToolOwner,
        workspaceName: String?
    ) async {
        guard let invocation = nativeToolInvocations.removeValue(
            forKey: call.id
        ) else {
            // A completion without its captured start belongs to an operation
            // that was reset or never admitted; it cannot be re-parented to
            // whichever turn happens to be current now.
            return
        }
        let rawOutputText = output.segments.compactMap { segment -> String? in
            switch segment {
            case .text(let value):
                return value.content
            case .structure(let value):
                return value.content.jsonString
            default:
                return nil
            }
        }.joined()
        let pluginResult = TypeScriptPluginToolResultCodec.decode(rawOutputText)
        let nativeResolution = await ToolReceiptRouter.resolve(
            for: call,
            output: output,
            registry: receiptRegistry,
            workspaceName: workspaceName
        )
        let outputText = pluginResult == nil
            ? nativeResolution.text
            : TypeScriptPluginToolResultCodec.visibleText(rawOutputText)
        let result = ToolResult(
            id: call.id,
            turnID: invocation.turnID,
            status: pluginResult?.isError == true ? .failed : .succeeded,
            output: outputText,
            errorMessage: pluginResult?.isError == true ? outputText : nil,
            durationMilliseconds: max(
                0,
                Int(Date().timeIntervalSince(invocation.startedAt) * 1_000)
            ),
            receipt: pluginResult?.widget.map(ToolReceipt.pluginWidget)
                ?? nativeResolution.receipt
        )
        guard await acceptBackendEvent(.toolFinished(result)) else { return }
        await diagnostics.toolFinished(
            call,
            output: output,
            backend: backend
        )
        let text = outputText
        if call.toolName == "turbocode_guide" {
            productGuidePresentation = ProductGuideBlock(toolOutput: text)
        } else if call.toolName == "write_ondevice",
                  text.hasPrefix("WRITE_COMPLETE: ") {
            completedRootWrite = String(
                text.dropFirst("WRITE_COMPLETE: ".count)
            )
        }
        if owner == .coordinator {
            coordinatorToolFinished(callID: call.id)
        }
        toolInteractions.endActivity(id: call.id)
    }

    /// Applies the provider-neutral delegation event stream and attaches a
    /// coordinator's pending delegate tool once the envelope supplies stable
    /// task and attempt identifiers.
    func agentActivityChanged(_ event: AgentActivityRuntimeEvent) {
        guard agentActivity.apply(event) else { return }
        if case .started = event {
            activityPresentationRequested()
        }
        switch event {
        case .started:
            if let pendingCoordinatorTool,
               let current = agentActivity.current {
                _ = agentActivity.beginTool(
                    pendingCoordinatorTool,
                    taskID: current.taskID,
                    attemptID: current.attemptID
                )
            }
        case .finished:
            pendingCoordinatorTool = nil
        case .phaseChanged, .toolStarted, .toolFinished:
            break
        }
    }

    func delegationChanged(_ value: Bool) {
        isDelegating = value
    }

    /// Coordinator callbacks are uncorrelated until `delegate_task` decodes its
    /// envelope. Other coordinator tools can attach directly to an active
    /// attempt, including future verification tools.
    private func coordinatorToolStarted(_ tool: AgentActivityTool) {
        if let current = agentActivity.current,
           !current.phase.isTerminal {
            _ = agentActivity.beginTool(
                tool,
                taskID: current.taskID,
                attemptID: current.attemptID
            )
        } else if tool.name == "delegate_task"
                    || tool.name == "call_powerful_model" {
            pendingCoordinatorTool = tool
        }
    }

    private func coordinatorToolFinished(callID: String) {
        if pendingCoordinatorTool?.callID == callID {
            pendingCoordinatorTool = nil
        }
        guard let current = agentActivity.current else { return }
        _ = agentActivity.finishTool(
            callID: callID,
            taskID: current.taskID,
            attemptID: current.attemptID
        )
    }

    /// Reuses the existing transient tool presentation while making route
    /// ownership readable before M2.3 introduces the dedicated Agent Route.
    /// Ordinary non-delegated tool calls retain their concise legacy summary.
    private func routedToolSummary(
        _ summary: String,
        toolName: String,
        owner: AgentActivityToolOwner
    ) -> String {
        let isDelegationBoundary = toolName == "delegate_task"
            || toolName == "call_powerful_model"
        guard agentActivity.current?.phase.isTerminal == false
                || isDelegationBoundary else {
            return summary
        }
        let label = owner == .coordinator ? "Coordinator" : "Worker"
        return "\(label) · \(summary)"
    }

    private static func toolSummary(
        for call: Transcript.ToolCall
    ) -> String {
        let path = (try? call.arguments.value(
            String.self,
            forProperty: "filePath"
        )) ?? (try? call.arguments.value(String.self, forProperty: "path"))
        let item = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch call.toolName {
        case "read_file":
            return ReadFileActivitySummary.make(
                filePath: try? call.arguments.value(
                    String.self,
                    forProperty: "filePath"
                ),
                startLine: try? call.arguments.value(
                    Int.self,
                    forProperty: "startLine"
                ),
                endLine: try? call.arguments.value(
                    Int.self,
                    forProperty: "endLine"
                ),
                limit: try? call.arguments.value(
                    Int.self,
                    forProperty: "limit"
                )
            )
        case "ripgrep", "grep":
            return RipgrepActivitySummary.make(
                action: try? call.arguments.value(
                    String.self,
                    forProperty: "action"
                ),
                pattern: try? call.arguments.value(
                    String.self,
                    forProperty: "pattern"
                ),
                path: try? call.arguments.value(
                    String.self,
                    forProperty: "path"
                ),
                filePattern: try? call.arguments.value(
                    String.self,
                    forProperty: "filePattern"
                ),
                filesOnly: try? call.arguments.value(
                    Bool.self,
                    forProperty: "filesOnly"
                )
            )
        case "bash":
            return "Running command"
        case "remove_file":
            return "Preparing file removal"
        case "git":
            let operation = try? call.arguments.value(
                String.self,
                forProperty: "operation"
            )
            return operation.map { "Git \($0)" } ?? "Working with Git"
        case "apply_edits", "edit_file":
            return "Preparing file changes"
        case "call_powerful_model":
            return "Working with coding model"
        case "turbocode_guide":
            return "Consulting TurboCode Guide"
        case "list_workspace":
            let path = try? call.arguments.value(
                String.self,
                forProperty: "path"
            )
            return path == "."
                ? "Browsing workspace"
                : "Browsing \(path ?? "workspace")"
        case "load_skill":
            let skill = try? call.arguments.value(
                String.self,
                forProperty: "skill"
            )
            return skill.map { "Loading \($0)" } ?? "Loading skill"
        case "file_system":
            let operation = try? call.arguments.value(
                String.self,
                forProperty: "operation"
            )
            switch operation {
            case "list": return item.map { "Listing \($0)" } ?? "Listing files"
            case "info": return item.map { "Inspecting \($0)" } ?? "Inspecting item"
            case "find": return item.map { "Finding files in \($0)" } ?? "Finding files"
            case "createDirectory": return item.map { "Creating \($0)" } ?? "Creating folder"
            case "write": return item.map { "Writing \($0)" } ?? "Writing file"
            case "append": return item.map { "Updating \($0)" } ?? "Updating file"
            case "copy": return item.map { "Copying \($0)" } ?? "Copying item"
            case "move": return item.map { "Moving \($0)" } ?? "Moving item"
            case "delete": return item.map { "Deleting \($0)" } ?? "Deleting item"
            default: return "Working with files"
            }
        default:
            return "Using \(call.toolName.replacingOccurrences(of: "_", with: " "))"
        }
    }

    /// Normalizes the app-owned approval request without leaking either
    /// Foundation Models or Codex request types into the runtime. The existing
    /// presentation ID is also the best stable tool correlation available at
    /// this compatibility boundary.
    private static func runtimeApproval(
        from request: ApprovalRequest,
        turnID: TurnID
    ) -> Approval {
        Approval(
            id: request.id,
            turnID: turnID,
            toolCallID: request.id,
            operation: request.operation,
            path: request.path,
            destination: request.destination,
            summary: request.summary
        )
    }

    private static func userVisibleAssistantText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
