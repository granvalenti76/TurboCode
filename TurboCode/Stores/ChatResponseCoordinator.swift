import Foundation
import FoundationModels
import FoundationModelsUtilities
import Observation

/// Coordinates one response lifecycle across a runtime and the chat timeline.
///
/// Provider loops remain in their dedicated runners. This coordinator maps
/// their outcomes into timeline blocks and tool presentation state; it does not
/// own conversation persistence, model selection, or workbench navigation.
@MainActor
@Observable
final class ChatResponseCoordinator {
    struct Result {
        let errorMessage: String?
        let touchedConversation: Bool
    }

    private let timeline: ChatTimelineStore
    private let toolInteractions: ToolInteractionStore
    private let agentActivity: AgentActivityStore
    private let codexRuntime: CodexRuntimeStore
    private let nativeRunner: any NativeResponseRunning

    private(set) var isDelegating = false
    private(set) var activeEditGroupID: String?
    private var activeDiagnosticsRunID: String?
    private var productGuidePresentation: ProductGuideBlock?
    private var completedRootWrite: String?
    private var pendingCoordinatorTool: AgentActivityTool?
    private(set) var currentTurnState: TurnState?

    init(
        timeline: ChatTimelineStore,
        toolInteractions: ToolInteractionStore,
        agentActivity: AgentActivityStore,
        codexRuntime: CodexRuntimeStore,
        nativeRunner: any NativeResponseRunning
    ) {
        self.timeline = timeline
        self.toolInteractions = toolInteractions
        self.agentActivity = agentActivity
        self.codexRuntime = codexRuntime
        self.nativeRunner = nativeRunner
    }

    /// Keeps the runtime identity at the coordinator boundary while the
    /// existing provider runners remain unchanged. A later callback may still
    /// arrive after cancellation, so presentation code can reject it by ID.
    func ownsTurn(_ turnID: TurnID) -> Bool {
        currentTurnState?.id == turnID && currentTurnState?.outcome == nil
    }

    private func beginTurn(_ request: TurnRequest) {
        currentTurnState = TurnState(
            id: request.id,
            startedAt: request.createdAt
        )
        _ = advanceTurn(to: .preparing, turnID: request.id)
    }

    @discardableResult
    private func advanceTurn(to phase: TurnPhase, turnID: TurnID) -> Bool {
        guard let currentTurnState,
              currentTurnState.id == turnID,
              let next = currentTurnState.transitioning(
                  to: phase,
                  at: Date()
              ) else {
            return false
        }
        self.currentTurnState = next
        return true
    }

    private func finishTurn(
        _ outcome: TurnOutcome,
        turnID: TurnID
    ) {
        guard let currentTurnState,
              currentTurnState.id == turnID,
              let next = currentTurnState.finishing(
                  with: outcome,
                  at: Date()
              ) else {
            return
        }
        self.currentTurnState = next
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
        agentTuning: AgentTuningConfig,
        availableSkills: [TurboCodeSkillDefinition],
        codexModelID: String?,
        codexReasoningEffort: CodexReasoningEffort?,
        delegationInvoker: (any AgentTaskInvoking)?,
        modelName: String
    ) async -> Result {
        let placeholderID = UUID().uuidString
        beginTurn(
            TurnRequest(
                id: turnID,
                prompt: promptText,
                backend: .codex,
                modelName: modelName,
                workspaceRoot: workspaceRoot
            )
        )
        _ = advanceTurn(to: .streaming, turnID: turnID)
        timeline.beginResponse(
            displayText: visibleInTimeline ? displayText : nil,
            placeholderID: placeholderID,
            model: modelName
        )
        var assistantText = ""
        var reasoningText = ""
        var result = Result(errorMessage: nil, touchedConversation: false)

        do {
            let response = try await codexRuntime.runTurn(
                request: CodexRuntimeStore.TurnRequest(
                    turnID: turnID,
                    turboThreadID: turboThreadID,
                    prompt: promptText,
                    workspaceRoot: workspaceRoot,
                    workspaceName: workspaceName,
                    agentTuning: agentTuning,
                    availableSkills: availableSkills,
                    modelID: codexModelID,
                    reasoningEffort: codexReasoningEffort,
                    delegationInvoker: delegationInvoker
                ),
                events: CodexRuntimeStore.TurnEvents(
                    liveAssistantChanged: { [weak self] text in
                        guard let self, self.ownsTurn(turnID) else { return }
                        assistantText = text
                        self.timeline.liveAssistant = text
                    },
                    liveReasoningChanged: { [weak self] text in
                        guard let self, self.ownsTurn(turnID) else { return }
                        reasoningText = text
                        self.timeline.liveReasoning = text
                    },
                    activityStarted: { [weak self] call, summary in
                        guard let self, self.ownsTurn(turnID) else { return }
                        _ = self.advanceTurn(
                            to: .toolExecuting,
                            turnID: turnID
                        )
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
                        guard let self, self.ownsTurn(turnID) else { return }
                        self.toolInteractions.endActivity(id: id)
                        self.coordinatorToolFinished(callID: id)
                        _ = self.advanceTurn(to: .streaming, turnID: turnID)
                    },
                    toolFinished: { _, _ in },
                    presentationRequested: { [weak self] presentation in
                        guard let self, self.ownsTurn(turnID) else { return }
                        self.present(presentation)
                    },
                    approvalRequested: { [weak self] request in
                        guard let self, self.ownsTurn(turnID) else { return }
                        _ = self.advanceTurn(
                            to: .awaitingApproval,
                            turnID: turnID
                        )
                        self.toolInteractions.enqueueApproval(request)
                    }
                )
            )
            guard ownsTurn(turnID) else {
                return Result(errorMessage: nil, touchedConversation: false)
            }
            assistantText = response.assistantText
            reasoningText = response.reasoningText
            let assistantBlock = assistantText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? nil : ChatBlock(
                id: placeholderID,
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
            timeline.finalizeResponse(
                placeholderID: placeholderID,
                assistantBlock: assistantBlock,
                reasoningBlock: reasoningBlock
            )
            _ = advanceTurn(to: .settling, turnID: turnID)
            finishTurn(.succeeded, turnID: turnID)
            result = Result(errorMessage: nil, touchedConversation: true)
        } catch where error is CancellationError || Task.isCancelled {
            guard ownsTurn(turnID) else {
                return Result(errorMessage: nil, touchedConversation: false)
            }
            await codexRuntime.interrupt()
            timeline.replaceBlock(
                id: placeholderID,
                with: ChatBlock(
                    id: placeholderID,
                    kind: .assistant,
                    text: assistantText.isEmpty
                        ? "Response interrupted."
                        : assistantText,
                    model: modelName
                )
            )
            finishTurn(.cancelled(reason: "The turn was interrupted."), turnID: turnID)
        } catch let codexError as CodexAppServerError
            where codexError.requiresChatGPTLogin {
            guard ownsTurn(turnID) else {
                return Result(errorMessage: nil, touchedConversation: false)
            }
            codexRuntime.markSignedOut()
            timeline.replaceBlock(
                id: placeholderID,
                with: ChatBlock(
                    id: placeholderID,
                    kind: .assistant,
                    text: "Sign in with ChatGPT to continue with Codex.",
                    model: modelName
                )
            )
            finishTurn(
                .failed(
                    TurnFailure(
                        code: "codex.authentication",
                        message: "Codex authentication is required.",
                        isRecoverable: true
                    )
                ),
                turnID: turnID
            )
        } catch {
            guard ownsTurn(turnID) else {
                return Result(errorMessage: nil, touchedConversation: false)
            }
            codexRuntime.markFailed(error.localizedDescription)
            timeline.replaceBlock(
                id: placeholderID,
                with: ChatBlock(
                    id: placeholderID,
                    kind: .assistant,
                    text: "Error: \(error.localizedDescription)",
                    model: modelName
                )
            )
            result = Result(
                errorMessage: error.localizedDescription,
                touchedConversation: false
            )
            finishTurn(
                .failed(
                    TurnFailure(
                        code: "codex.request",
                        message: error.localizedDescription
                    )
                ),
                turnID: turnID
            )
        }

        guard ownsTurn(turnID) || currentTurnState?.id == turnID else {
            return Result(errorMessage: nil, touchedConversation: false)
        }
        timeline.finishResponse(placeholderID: placeholderID)
        toolInteractions.clearActivities()
        return result
    }

    func performNative(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool,
        turnID: TurnID,
        blocks: [ChatBlock],
        session: LanguageModelSession,
        backend: ModelBackend,
        mode: OrchestratorMode,
        workspaceKind: String,
        workspaceRoot: String,
        modelName: String,
        serverURL: String? = nil,
        reasoningStreamRelay: ReasoningStreamRelay? = nil,
        contextChanged: @escaping @MainActor @Sendable (LlamaContextUsage?) -> Void = { _ in }
    ) async -> Result {
        let modelPrompt = WorkspaceListingFollowUpContext.enriching(
            promptText,
            blocks: blocks
        )
        let editGroupID = UUID().uuidString
        activeEditGroupID = editGroupID
        let placeholderID = UUID().uuidString
        beginTurn(
            TurnRequest(
                id: turnID,
                prompt: promptText,
                backend: backend,
                modelName: modelName,
                workspaceRoot: workspaceRoot
            )
        )
        timeline.beginResponse(
            displayText: visibleInTimeline ? displayText : nil,
            placeholderID: placeholderID,
            model: modelName
        )
        productGuidePresentation = nil
        completedRootWrite = nil

        let backendSession = NativeBackendSession(
            backend: backend,
            runner: nativeRunner,
            session: session,
            mode: mode,
            workspaceKind: workspaceKind,
            serverURL: serverURL,
            reasoningStreamRelay: reasoningStreamRelay,
            diagnosticsChanged: { [weak self] runID in
                guard let self, self.ownsTurn(turnID) else { return }
                self.activeDiagnosticsRunID = runID
            },
            contextChanged: { [weak self] usage in
                guard let self, self.ownsTurn(turnID) else { return }
                contextChanged(usage)
            },
            approvalRequested: { [weak self] request in
                guard let self, self.ownsTurn(turnID) else { return }
                _ = self.advanceTurn(
                    to: .awaitingApproval,
                    turnID: turnID
                )
                self.toolInteractions.enqueueApproval(request)
            }
        )
        let backendResult = await backendSession.run(
            request: TurnRequest(
                id: turnID,
                prompt: modelPrompt,
                backend: backend,
                modelName: modelName,
                workspaceRoot: workspaceRoot
            ),
            events: BackendSessionEvents { [weak self] event in
                guard let self, event.turnID == turnID, self.ownsTurn(turnID) else {
                    return
                }
                switch event {
                case .assistantTextChanged(_, let content):
                    self.timeline.liveAssistant =
                        Self.userVisibleAssistantText(content)
                case .reasoningTextChanged(_, let reasoning):
                    self.timeline.liveReasoning = reasoning
                case .phaseChanged(_, let phase, _):
                    _ = self.advanceTurn(to: phase, turnID: turnID)
                default:
                    break
                }
            }
        )
        _ = advanceTurn(to: .streaming, turnID: turnID)
        isDelegating = false
        guard ownsTurn(turnID) else {
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
                workspaceListings: timeline.workspaceListingPresentations
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
            timeline.finalizeResponse(
                placeholderID: placeholderID,
                assistantBlock: assistantBlock,
                reasoningBlock: reasoningBlock
            )
            _ = advanceTurn(to: .settling, turnID: turnID)
            finishTurn(.succeeded, turnID: turnID)
            result = Result(errorMessage: nil, touchedConversation: true)
        case .failed(let failure) where failure.code == "native.repetitiveOutput":
            let stoppedText = completedRootWrite.map { "Created `\($0)`." }
                ?? "Response stopped because the on-device model began repeating output. Please retry."
            timeline.replaceBlock(
                id: placeholderID,
                with: ChatBlock(
                    id: placeholderID,
                    kind: .assistant,
                    text: stoppedText,
                    model: modelName
                )
            )
            finishTurn(
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
            let partialText = content.isEmpty ? reasoning : content
            timeline.replaceBlock(
                id: placeholderID,
                with: ChatBlock(
                    id: placeholderID,
                    kind: .assistant,
                    text: partialText.isEmpty
                        ? "Response interrupted."
                        : partialText,
                    model: modelName
                )
            )
            finishTurn(
                .cancelled(reason: "The turn was interrupted."),
                turnID: turnID
            )
        case .failed(let failure):
            let message = failure.message
            timeline.replaceBlock(
                id: placeholderID,
                with: ChatBlock(
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
            finishTurn(
                .failed(TurnFailure(code: "provider.request", message: message)),
                turnID: turnID
            )
        }

        timeline.liveReasoning = ""
        timeline.liveAssistant = ""
        if activeEditGroupID == editGroupID {
            activeEditGroupID = nil
        }
        timeline.finishResponse(placeholderID: placeholderID)
        timeline.clearEditGroup(editGroupID)
        return result
    }

    func toolStarted(
        _ call: Transcript.ToolCall,
        backend: ModelBackend,
        owner: AgentActivityToolOwner
    ) async {
        if let turnID = currentTurnState?.id {
            _ = advanceTurn(to: .toolExecuting, turnID: turnID)
        }
        if let activeDiagnosticsRunID {
            await AgentDiagnosticsRecorder.shared.toolStarted(
                runID: activeDiagnosticsRunID,
                call: call,
                backend: backend
            )
        }
        if owner == .coordinator {
            coordinatorToolStarted(
                AgentActivityRuntimeMapping.tool(from: call, owner: owner)
            )
        }
        guard call.toolName != "diff_patch",
              call.toolName != "apply_edits",
              call.toolName != "edit_file" else { return }
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
        if let activeDiagnosticsRunID {
            await AgentDiagnosticsRecorder.shared.toolFinished(
                runID: activeDiagnosticsRunID,
                call: call,
                output: output,
                backend: backend
            )
        }
        let text = output.segments.compactMap { segment -> String? in
            guard case .text(let value) = segment else { return nil }
            return value.content
        }.joined()
        if call.toolName == "turbocode_guide" {
            productGuidePresentation = ProductGuideBlock(toolOutput: text)
        } else if call.toolName == "write_ondevice",
                  text.hasPrefix("WRITE_COMPLETE: ") {
            completedRootWrite = String(
                text.dropFirst("WRITE_COMPLETE: ".count)
            )
        }
        if let presentation = ToolPresentationRouter.presentation(
            for: call,
            output: output,
            workspaceName: workspaceName
        ) {
            present(presentation)
        }
        if owner == .coordinator {
            coordinatorToolFinished(callID: call.id)
        }
        toolInteractions.endActivity(id: call.id)
        if let turnID = currentTurnState?.id {
            _ = advanceTurn(to: .streaming, turnID: turnID)
        }
    }

    /// Applies the provider-neutral delegation event stream and attaches a
    /// coordinator's pending delegate tool once the envelope supplies stable
    /// task and attempt identifiers.
    func agentActivityChanged(_ event: AgentActivityRuntimeEvent) {
        guard agentActivity.apply(event) else { return }
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

    private func present(_ presentation: ToolPresentation) {
        switch presentation {
        case .workspaceListing(let listing):
            timeline.presentWorkspaceListing(listing)
        }
    }

    private func present(_ presentation: CodexToolPresentation) {
        switch presentation {
        case .workspaceListing(let listing):
            timeline.presentWorkspaceListing(listing)
        }
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

    private static func userVisibleAssistantText(_ text: String) -> String {
        let approvalKeys = Set([
            "approval_id", "operation", "path", "destination", "summary"
        ])
        var isSkippingApproval = false
        var visibleLines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if trimmed.contains("TURBOCODE_APPROVAL_REQUIRED") {
                isSkippingApproval = true
                continue
            }
            if isSkippingApproval {
                let key = trimmed.split(
                    separator: ":",
                    maxSplits: 1
                ).first.map(String.init) ?? ""
                if trimmed.isEmpty || approvalKeys.contains(key) {
                    continue
                }
                isSkippingApproval = false
            }
            visibleLines.append(line)
        }
        return visibleLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
