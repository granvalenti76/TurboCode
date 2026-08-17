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

    /// Carries profile-owned Codex choices across the timeline boundary while
    /// leaving provider selection and persistence in their owning stores.
    func performCodex(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool,
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
                        assistantText = text
                        self?.timeline.liveAssistant = text
                    },
                    liveReasoningChanged: { [weak self] text in
                        reasoningText = text
                        self?.timeline.liveReasoning = text
                    },
                    activityStarted: { [weak self] call, summary in
                        guard let self else { return }
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
                        self?.toolInteractions.endActivity(id: id)
                        self?.coordinatorToolFinished(callID: id)
                    },
                    presentationRequested: { [weak self] presentation in
                        self?.present(presentation)
                    },
                    approvalRequested: { [weak self] request in
                        self?.toolInteractions.enqueueApproval(request)
                    }
                )
            )
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
            result = Result(errorMessage: nil, touchedConversation: true)
        } catch where error is CancellationError || Task.isCancelled {
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
        } catch let codexError as CodexAppServerError
            where codexError.requiresChatGPTLogin {
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
        } catch {
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
        }

        timeline.finishResponse(placeholderID: placeholderID)
        toolInteractions.clearActivities()
        return result
    }

    func performNative(
        displayText: String,
        promptText: String,
        visibleInTimeline: Bool,
        blocks: [ChatBlock],
        session: LanguageModelSession,
        backend: ModelBackend,
        mode: OrchestratorMode,
        workspaceKind: String,
        modelName: String,
        serverURL: String? = nil
    ) async -> Result {
        let modelPrompt = WorkspaceListingFollowUpContext.enriching(
            promptText,
            blocks: blocks
        )
        let editGroupID = UUID().uuidString
        activeEditGroupID = editGroupID
        let placeholderID = UUID().uuidString
        timeline.beginResponse(
            displayText: visibleInTimeline ? displayText : nil,
            placeholderID: placeholderID,
            model: modelName
        )
        productGuidePresentation = nil
        completedRootWrite = nil

        let outcome = await nativeRunner.run(
            session: session,
            request: NativeResponseRunner.Request(
                prompt: modelPrompt,
                backend: backend,
                mode: mode,
                workspaceKind: workspaceKind,
                serverURL: serverURL
            ),
            events: NativeResponseRunner.Events(
                diagnosticsChanged: { [weak self] runID in
                    self?.activeDiagnosticsRunID = runID
                },
                liveContentChanged: { [weak self] content in
                    self?.timeline.liveAssistant =
                        Self.userVisibleAssistantText(content)
                },
                liveReasoningChanged: { [weak self] reasoning in
                    self?.timeline.liveReasoning = reasoning
                },
                approvalRequested: { [weak self] request in
                    self?.toolInteractions.enqueueApproval(request)
                }
            )
        )
        isDelegating = false
        toolInteractions.clearActivities()
        var result = Result(errorMessage: nil, touchedConversation: false)

        switch outcome {
        case .completed(let content, let reasoning):
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
            result = Result(errorMessage: nil, touchedConversation: true)
        case .repetitiveOutput:
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
        case .cancelled(let content, let reasoning):
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
        case .failed(let message, _, _):
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
