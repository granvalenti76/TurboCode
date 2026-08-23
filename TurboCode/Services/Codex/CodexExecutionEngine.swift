import Foundation
import FoundationModels

/// Immutable input for one Codex App Server turn.
///
/// UI preferences are resolved before this value crosses into the execution
/// actor. The engine therefore never reads an observable store or UserDefaults
/// while a provider turn is active.
nonisolated struct CodexTurnRequest: Sendable {
    let turnID: TurnID
    let turboThreadID: String
    let prompt: String
    let workspaceRoot: String
    let workspaceName: String?
    let agentTuning: AgentTuningConfig
    let availableSkills: [TurboCodeSkillDefinition]
    let modelID: String
    let reasoningEffort: CodexReasoningEffort
    let persistsModelPreference: Bool
    let delegationInvoker: (any AgentTaskInvoking)?
    let pluginTools: [TypeScriptPluginToolBinding]

    init(
        turnID: TurnID,
        turboThreadID: String,
        prompt: String,
        workspaceRoot: String,
        workspaceName: String?,
        agentTuning: AgentTuningConfig,
        availableSkills: [TurboCodeSkillDefinition],
        modelID: String,
        reasoningEffort: CodexReasoningEffort,
        persistsModelPreference: Bool,
        delegationInvoker: (any AgentTaskInvoking)?,
        pluginTools: [TypeScriptPluginToolBinding] = []
    ) {
        self.turnID = turnID
        self.turboThreadID = turboThreadID
        self.prompt = prompt
        self.workspaceRoot = workspaceRoot
        self.workspaceName = workspaceName
        self.agentTuning = agentTuning
        self.availableSkills = availableSkills
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.persistsModelPreference = persistsModelPreference
        self.delegationInvoker = delegationInvoker
        self.pluginTools = pluginTools
    }
}

nonisolated struct CodexTurnResult: Sendable {
    let assistantText: String
    let reasoningText: String
}

/// Ordered output ports for execution state that must be projected elsewhere.
/// The closures are deliberately executor-neutral; callers choose which events
/// require a MainActor hop instead of pinning the App Server loop to the UI.
nonisolated struct CodexTurnEvents: Sendable {
    let runtimeSnapshotChanged: @Sendable (
        CodexRuntimeSnapshot,
        Bool
    ) async -> Void
    let liveAssistantChanged: @Sendable (String) async -> Void
    let liveReasoningChanged: @Sendable (String) async -> Void
    let activityStarted: @Sendable (CodexDynamicToolCall, String) async -> Void
    let activityEnded: @Sendable (String) async -> Void
    let toolFinished: @Sendable (
        CodexDynamicToolCall,
        CodexDynamicToolResult,
        ToolReceipt?
    ) async -> Void
    let approvalRequested: @Sendable (ApprovalRequest) async -> Void
}

nonisolated struct CodexHandoff: Sendable {
    let history: [Transcript.Entry]
    let didSummarize: Bool
}

/// Narrow transport port owned by the execution actor. The official App Server
/// client is one implementation; deterministic tests can prove engine state
/// transitions without launching an external process.
nonisolated protocol CodexAppServerServing: Sendable {
    func prepareCodex(
        selectedModelID: String?
    ) async throws -> CodexRuntimeSnapshot
    func startChatGPTLogin() async throws -> CodexLoginSession
    func waitForChatGPTLogin(id: String) async throws
    func startThread(
        workspaceRoot: String,
        modelID: String,
        dynamicTools: [CodexDynamicToolSpec],
        developerInstructions: String
    ) async throws -> String
    func startTurn(
        threadID: String,
        text: String,
        workspaceRoot: String,
        modelID: String,
        effort: CodexReasoningEffort,
        additionalApplicationContext: String?
    ) async throws -> AsyncThrowingStream<CodexTurnEvent, any Error>
    func interruptActiveTurn() async
    func resolveApproval(
        _ request: CodexApprovalRequest,
        approved: Bool
    ) async throws
    func resolveToolCall(
        _ call: CodexDynamicToolCall,
        result: CodexDynamicToolResult
    ) async throws
}

extension CodexAppServerClient: CodexAppServerServing {}

/// Owns all mutable Codex transport and server-thread state.
///
/// This actor is the future library-facing execution boundary. It has no
/// Observation, AppKit, SwiftUI, UserDefaults, conversation store, or timeline
/// dependency. A UI host may project its value outputs, while another host can
/// drive the same engine without instantiating TurboCode's interface.
actor CodexExecutionEngine {
    private struct ThreadConfiguration: Equatable {
        let includesDelegation: Bool
        let safariMCPEnabled: Bool
        let modelID: String
        let skillNames: [String]
        let pluginToolNames: [String]
    }

    private let client: any CodexAppServerServing
    private var threadIDs: [String: String] = [:]
    private var threadConfigurations: [String: ThreadConfiguration] = [:]
    private var tokenUsageByThread: [String: CodexTokenUsage] = [:]
    private var importedContexts: [String: String] = [:]
    private var handoffBoundaryBlockIDs: [String: String] = [:]
    private var approvals: [String: CodexApprovalRequest] = [:]

    init(client: any CodexAppServerServing = CodexAppServerClient()) {
        self.client = client
    }

    func prepareCodex(selectedModelID: String?) async throws -> CodexRuntimeSnapshot {
        try await client.prepareCodex(selectedModelID: selectedModelID)
    }

    func startChatGPTLogin() async throws -> CodexLoginSession {
        try await client.startChatGPTLogin()
    }

    func waitForChatGPTLogin(id: String) async throws {
        try await client.waitForChatGPTLogin(id: id)
    }

    /// Captures only turns not already known by the process-local Codex thread.
    func captureImportedContext(turboThreadID: String, blocks: [ChatBlock]) {
        let context = RuntimeContextHandoff.render(
            blocks: blocks,
            after: handoffBoundaryBlockIDs[turboThreadID]
        )
        if !context.isEmpty {
            importedContexts[turboThreadID] = context
        }
    }

    /// Restored Codex identifiers are process-local, so a visible persisted
    /// timeline initializes the next fresh App Server thread.
    func restoreImportedContext(turboThreadID: String, blocks: [ChatBlock]) {
        let context = RuntimeContextHandoff.render(blocks: blocks)
        if !context.isEmpty {
            importedContexts[turboThreadID] = context
        }
    }

    func prepareHandoff(
        turboThreadID: String,
        blocks: [ChatBlock],
        workspaceRoot: String,
        modelID: String
    ) async -> CodexHandoff {
        let usage = tokenUsageByThread[turboThreadID]
        let requiresSummary = RuntimeContextHandoff.shouldSummarizeCodexContext(
            lastTotalTokens: usage?.lastTotalTokens
        )
        if requiresSummary,
           let summary = try? await requestHandoffSummary(
                turboThreadID: turboThreadID,
                workspaceRoot: workspaceRoot,
                modelID: modelID
           ),
           !summary.isEmpty {
            return CodexHandoff(
                history: RuntimeContextHandoff.transcript(fromSummary: summary),
                didSummarize: true
            )
        }
        if requiresSummary {
            let fallback = RuntimeContextHandoff.render(
                blocks: blocks,
                maximumCharacters: 24_000
            )
            return CodexHandoff(
                history: RuntimeContextHandoff.transcript(fromSummary: fallback),
                didSummarize: false
            )
        }
        return CodexHandoff(
            history: RuntimeContextHandoff.transcript(from: blocks),
            didSummarize: false
        )
    }

    func completeHandoff(turboThreadID: String, boundaryBlockID: String?) {
        handoffBoundaryBlockIDs[turboThreadID] = boundaryBlockID
        importedContexts.removeValue(forKey: turboThreadID)
    }

    /// App Server tool declarations are immutable for one thread. Route
    /// changes therefore discard only hidden server identity and usage state.
    func resetThread(turboThreadID: String) {
        threadIDs.removeValue(forKey: turboThreadID)
        threadConfigurations.removeValue(forKey: turboThreadID)
        tokenUsageByThread.removeValue(forKey: turboThreadID)
    }

    func runTurn(
        request: CodexTurnRequest,
        events: CodexTurnEvents
    ) async throws -> CodexTurnResult {
        let snapshot = try await client.prepareCodex(
            selectedModelID: request.modelID
        )
        await events.runtimeSnapshotChanged(
            snapshot,
            request.persistsModelPreference
        )

        let includesDelegation = request.delegationInvoker != nil
        let pluginTools = request.agentTuning.experimental.thirdPartyPluginsEnabled
            ? request.pluginTools
            : []
        let configuration = ThreadConfiguration(
            includesDelegation: includesDelegation,
            safariMCPEnabled: request.agentTuning.experimental.safariMCPEnabled,
            modelID: snapshot.selectedModel.id,
            skillNames: request.availableSkills.map(\.name),
            pluginToolNames: pluginTools.map { $0.snapshot.id.rawValue }
        )
        let threadID: String
        if let existing = threadIDs[request.turboThreadID],
           threadConfigurations[request.turboThreadID] == configuration {
            threadID = existing
        } else {
            let dynamicTools = CodexTurboCodeToolBridge.specifications(
                workspaceRoot: request.workspaceRoot,
                agentTuning: request.agentTuning,
                includesDelegation: includesDelegation,
                availableSkills: request.availableSkills,
                safariMCPEnabled: request.agentTuning.experimental.safariMCPEnabled,
                pluginTools: pluginTools
            )
            let workspaceInstructions = WorkspaceInstructionsLoader.load(
                from: request.workspaceRoot
            )
            let developerInstructions = CodexTurboCodeToolBridge.developerInstructions(
                workspaceRoot: request.workspaceRoot,
                agentTuning: request.agentTuning,
                dynamicTools: dynamicTools,
                availableSkills: request.availableSkills,
                workspaceInstructions: workspaceInstructions
            )
            threadID = try await client.startThread(
                workspaceRoot: request.workspaceRoot,
                modelID: snapshot.selectedModel.model,
                dynamicTools: dynamicTools,
                developerInstructions: developerInstructions
            )
            threadIDs[request.turboThreadID] = threadID
            threadConfigurations[request.turboThreadID] = configuration
        }

        let effectiveEffort = snapshot.selectedModel.supportedReasoningEfforts
            .contains(where: {
                $0.reasoningEffort == request.reasoningEffort
            })
            ? request.reasoningEffort
            : snapshot.selectedModel.defaultReasoningEffort
        let stream = try await client.startTurn(
            threadID: threadID,
            text: request.prompt,
            workspaceRoot: request.workspaceRoot,
            modelID: snapshot.selectedModel.model,
            effort: effectiveEffort,
            additionalApplicationContext: importedContexts[request.turboThreadID]
        )
        var assistantText = ""
        var reasoningText = ""
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .agentDelta(let delta):
                assistantText += delta
                await events.liveAssistantChanged(assistantText)
            case .reasoningDelta(let delta):
                reasoningText += delta
                await events.liveReasoningChanged(reasoningText)
            case .diffUpdated:
                break
            case .toolCallRequested(let call):
                await events.activityStarted(
                    call,
                    CodexTurboCodeToolBridge.activitySummary(for: call)
                )
                let result: CodexDynamicToolResult
                let receipt: ToolReceipt?
                do {
                    let execution = try await CodexTurboCodeToolBridge.execute(
                        call,
                        workspaceRoot: request.workspaceRoot,
                        workspaceName: request.workspaceName,
                        agentTuning: request.agentTuning,
                        availableSkills: request.availableSkills,
                        pluginTools: pluginTools,
                        delegationInvoker: request.delegationInvoker,
                        parentTurnID: request.turnID
                    )
                    result = execution.result
                    receipt = execution.receipt
                } catch {
                    result = .failure(error.localizedDescription)
                    receipt = nil
                }
                await events.toolFinished(call, result, receipt)
                await events.activityEnded(call.callID)
                try await client.resolveToolCall(call, result: result)
            case .approvalRequested(let approval):
                approvals[approval.presentationID] = approval
                await events.approvalRequested(
                    ApprovalRequest(
                        id: approval.presentationID,
                        operation: approval.operation,
                        path: approval.path,
                        summary: approval.summary
                    )
                )
            case .tokenUsageUpdated(let usage):
                tokenUsageByThread[request.turboThreadID] = usage
            case .completed(let status, let errorMessage):
                if status == "failed" {
                    throw CodexAppServerError.turnFailed(
                        errorMessage ?? "Codex turn failed."
                    )
                }
            }
        }
        try Task.checkCancellation()
        return CodexTurnResult(
            assistantText: assistantText,
            reasoningText: reasoningText
        )
    }

    func resolveApproval(id: String, approved: Bool) async throws -> Bool {
        guard let request = approvals.removeValue(forKey: id) else {
            return false
        }
        try await client.resolveApproval(request, approved: approved)
        return true
    }

    func interrupt() async {
        await client.interruptActiveTurn()
    }

    /// Hidden compaction turns cannot execute tools or approve mutations.
    private func requestHandoffSummary(
        turboThreadID: String,
        workspaceRoot: String,
        modelID: String
    ) async throws -> String {
        guard let threadID = threadIDs[turboThreadID] else {
            throw CodexAppServerError.invalidResponse(
                "missing Codex thread for context handoff"
            )
        }
        let prompt = """
        Prepare a compact technical handoff for another coding model. Do not \
        call tools and do not continue the task. Include: the user's objective, \
        decisions and constraints, files changed or inspected, completed \
        validations, current repository/runtime state, unresolved issues, and \
        the exact next useful action. Preserve concrete paths, identifiers, and \
        errors. Omit private reasoning and conversational filler.
        """
        let stream = try await client.startTurn(
            threadID: threadID,
            text: prompt,
            workspaceRoot: workspaceRoot,
            modelID: modelID,
            effort: .low,
            additionalApplicationContext: nil
        )
        var summary = ""
        for try await event in stream {
            switch event {
            case .agentDelta(let delta):
                summary += delta
            case .toolCallRequested(let call):
                try await client.resolveToolCall(
                    call,
                    result: .failure(
                        "Tools are disabled while preparing a runtime handoff."
                    )
                )
            case .approvalRequested(let request):
                try await client.resolveApproval(request, approved: false)
            case .tokenUsageUpdated(let usage):
                tokenUsageByThread[turboThreadID] = usage
            case .completed(let status, let errorMessage):
                if status == "failed" {
                    throw CodexAppServerError.turnFailed(
                        errorMessage ?? "Codex context summary failed."
                    )
                }
            case .reasoningDelta, .diffUpdated:
                break
            }
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Injectable transport boundary used by `CodexBackendSession` evaluations.
nonisolated protocol CodexTurnRunning: AnyObject, Sendable {
    func runTurn(
        request: CodexTurnRequest,
        events: CodexTurnEvents
    ) async throws -> CodexTurnResult

    func interrupt() async
}

extension CodexExecutionEngine: CodexTurnRunning {}
