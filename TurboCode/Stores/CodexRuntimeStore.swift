import AppKit
import Foundation
import Observation
import FoundationModels

/// Owns the complete Codex App Server lifecycle.
///
/// Authentication, model discovery, server thread identity, token accounting,
/// context handoff, approvals, and dynamic-tool execution all belong to this
/// bounded runtime. The store emits presentation events but never mutates chat
/// blocks, conversations, workspace selection, or navigation.
@MainActor
@Observable
final class CodexRuntimeStore {
    struct TurnRequest {
        let turboThreadID: String
        let prompt: String
        let workspaceRoot: String
        let workspaceName: String?
        let agentTuning: AgentTuningConfig
    }

    struct TurnResult {
        let assistantText: String
        let reasoningText: String
    }

    struct TurnEvents {
        let liveAssistantChanged: (String) -> Void
        let liveReasoningChanged: (String) -> Void
        let activityStarted: (String, String) -> Void
        let activityEnded: (String) -> Void
        let presentationRequested: (CodexToolPresentation) -> Void
        let approvalRequested: (ApprovalRequest) -> Void
    }

    struct Handoff {
        let history: [Transcript.Entry]
        let didSummarize: Bool
    }

    var connectionState: CodexConnectionState = .idle
    var model: CodexModelDescriptor?
    var models: [CodexModelDescriptor] = []
    var loginURL: URL?
    var reasoningEffort: CodexReasoningEffort =
        UserDefaults.standard.string(forKey: "codexReasoningEffort")
            .flatMap(CodexReasoningEffort.init(rawValue:))
        ?? .medium

    var reasoningOptions: [CodexReasoningOption] {
        model?.supportedReasoningEfforts
            ?? CodexReasoningEffort.allCases.map {
                CodexReasoningOption(reasoningEffort: $0, description: "")
            }
    }

    var displayName: String {
        model?.displayName
            ?? UserDefaults.standard.string(forKey: "codexModelDisplayName")
            ?? "Luna"
    }

    var canSend: Bool {
        if case .ready = connectionState { return true }
        return false
    }

    private let client: CodexAppServerClient
    private var preferredModelID: String =
        UserDefaults.standard.string(forKey: "codexModelID")
            ?? CodexAppServerClient.lunaModelID
    private var threadIDs: [String: String] = [:]
    private var tokenUsageByThread: [String: CodexTokenUsage] = [:]
    private var importedContexts: [String: String] = [:]
    private var handoffBoundaryBlockIDs: [String: String] = [:]
    private var approvals: [String: CodexApprovalRequest] = [:]

    init(client: CodexAppServerClient = CodexAppServerClient()) {
        self.client = client
    }

    func select(modelID: String? = nil) async throws {
        if let modelID {
            preferredModelID = modelID
            UserDefaults.standard.set(modelID, forKey: "codexModelID")
        }
        connectionState = .connecting
        let snapshot = try await client.prepareCodex(
            selectedModelID: preferredModelID
        )
        apply(snapshot)
    }

    func markSignedOut() {
        connectionState = .signedOut
    }

    func markFailed(_ message: String) {
        connectionState = .failed(message)
    }

    func signIn() async throws {
        connectionState = .authenticating
        let login = try await client.startChatGPTLogin()
        loginURL = login.authorizationURL
        guard NSWorkspace.shared.open(login.authorizationURL) else {
            throw CodexAppServerError.loginFailed(
                "The authorization page could not be opened."
            )
        }
        try await client.waitForChatGPTLogin(id: login.id)
        connectionState = .connecting
        let snapshot = try await client.prepareCodex(
            selectedModelID: preferredModelID
        )
        apply(snapshot)
        loginURL = nil
    }

    @discardableResult
    func reopenLoginPage() -> Bool {
        guard let loginURL else { return false }
        return NSWorkspace.shared.open(loginURL)
    }

    func setReasoningEffort(_ effort: CodexReasoningEffort) {
        guard reasoningOptions.contains(where: {
            $0.reasoningEffort == effort
        }) else { return }
        reasoningEffort = effort
        UserDefaults.standard.set(
            effort.rawValue,
            forKey: "codexReasoningEffort"
        )
    }

    /// Captures only turns not already known by the process-local Codex thread.
    func captureImportedContext(
        turboThreadID: String,
        blocks: [ChatBlock]
    ) {
        let context = RuntimeContextHandoff.render(
            blocks: blocks,
            after: handoffBoundaryBlockIDs[turboThreadID]
        )
        if !context.isEmpty {
            importedContexts[turboThreadID] = context
        }
    }

    /// Restored Codex identifiers are process-local, so the visible persisted
    /// timeline initializes the next fresh App Server thread.
    func restoreImportedContext(
        turboThreadID: String,
        blocks: [ChatBlock]
    ) {
        let context = RuntimeContextHandoff.render(blocks: blocks)
        if !context.isEmpty {
            importedContexts[turboThreadID] = context
        }
    }

    func prepareHandoff(
        turboThreadID: String,
        blocks: [ChatBlock],
        workspaceRoot: String
    ) async -> Handoff {
        let usage = tokenUsageByThread[turboThreadID]
        let requiresSummary = RuntimeContextHandoff.shouldSummarizeCodexContext(
            lastTotalTokens: usage?.lastTotalTokens
        )
        if requiresSummary,
           let summary = try? await requestHandoffSummary(
                turboThreadID: turboThreadID,
                workspaceRoot: workspaceRoot
           ),
           !summary.isEmpty {
            return Handoff(
                history: RuntimeContextHandoff.transcript(fromSummary: summary),
                didSummarize: true
            )
        }
        if requiresSummary {
            let fallback = RuntimeContextHandoff.render(
                blocks: blocks,
                maximumCharacters: 24_000
            )
            return Handoff(
                history: RuntimeContextHandoff.transcript(
                    fromSummary: fallback
                ),
                didSummarize: false
            )
        }
        return Handoff(
            history: RuntimeContextHandoff.transcript(from: blocks),
            didSummarize: false
        )
    }

    func completeHandoff(
        turboThreadID: String,
        boundaryBlockID: String?
    ) {
        handoffBoundaryBlockIDs[turboThreadID] = boundaryBlockID
        importedContexts.removeValue(forKey: turboThreadID)
    }

    func runTurn(
        request: TurnRequest,
        events: TurnEvents
    ) async throws -> TurnResult {
        let snapshot = try await client.prepareCodex(
            selectedModelID: preferredModelID
        )
        apply(snapshot)

        let threadID: String
        if let existing = threadIDs[request.turboThreadID] {
            threadID = existing
        } else {
            let dynamicTools = CodexTurboCodeToolBridge.specifications(
                workspaceRoot: request.workspaceRoot,
                agentTuning: request.agentTuning
            )
            let workspaceInstructions = WorkspaceInstructionsLoader.load(
                from: request.workspaceRoot
            )
            let developerInstructions = CodexTurboCodeToolBridge.developerInstructions(
                workspaceRoot: request.workspaceRoot,
                agentTuning: request.agentTuning,
                dynamicTools: dynamicTools,
                workspaceInstructions: workspaceInstructions
            )
            // App Server instructions are sticky for the thread. Keeping them
            // fixed preserves Codex context and cache reuse across later turns.
            threadID = try await client.startThread(
                workspaceRoot: request.workspaceRoot,
                modelID: snapshot.selectedModel.model,
                dynamicTools: dynamicTools,
                developerInstructions: developerInstructions
            )
            threadIDs[request.turboThreadID] = threadID
        }

        let stream = try await client.startTurn(
            threadID: threadID,
            text: request.prompt,
            workspaceRoot: request.workspaceRoot,
            modelID: snapshot.selectedModel.model,
            effort: reasoningEffort,
            additionalApplicationContext:
                importedContexts[request.turboThreadID]
        )
        var assistantText = ""
        var reasoningText = ""
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .agentDelta(let delta):
                assistantText += delta
                events.liveAssistantChanged(assistantText)
            case .reasoningDelta(let delta):
                reasoningText += delta
                events.liveReasoningChanged(reasoningText)
            case .diffUpdated:
                // Supported edits use apply_edits, whose review transaction is
                // authoritative in TurboCode.
                break
            case .toolCallRequested(let call):
                events.activityStarted(
                    call.callID,
                    CodexTurboCodeToolBridge.activitySummary(for: call.tool)
                )
                let result: CodexDynamicToolResult
                do {
                    let execution = try await CodexTurboCodeToolBridge.execute(
                        call,
                        workspaceRoot: request.workspaceRoot,
                        workspaceName: request.workspaceName,
                        agentTuning: request.agentTuning
                    )
                    if let presentation = execution.presentation {
                        events.presentationRequested(presentation)
                    }
                    result = execution.result
                } catch {
                    result = .failure(error.localizedDescription)
                }
                events.activityEnded(call.callID)
                try await client.resolveToolCall(call, result: result)
            case .approvalRequested(let approval):
                approvals[approval.presentationID] = approval
                events.approvalRequested(
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
                    // A failed turn is a valid App Server response and may be
                    // transient (such as model capacity), not malformed JSON.
                    throw CodexAppServerError.turnFailed(
                        errorMessage ?? "Codex turn failed."
                    )
                }
            }
        }
        try Task.checkCancellation()
        return TurnResult(
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

    private func apply(_ snapshot: CodexRuntimeSnapshot) {
        models = snapshot.models
        model = snapshot.selectedModel
        preferredModelID = snapshot.selectedModel.id
        UserDefaults.standard.set(
            snapshot.selectedModel.id,
            forKey: "codexModelID"
        )
        UserDefaults.standard.set(
            snapshot.selectedModel.displayName,
            forKey: "codexModelDisplayName"
        )
        if !snapshot.selectedModel.supportedReasoningEfforts.contains(where: {
            $0.reasoningEffort == reasoningEffort
        }) {
            reasoningEffort = snapshot.selectedModel.defaultReasoningEffort
            UserDefaults.standard.set(
                reasoningEffort.rawValue,
                forKey: "codexReasoningEffort"
            )
        }
        connectionState = .ready(planType: snapshot.planType)
    }

    /// Hidden compaction turns cannot execute tools or approve mutations.
    private func requestHandoffSummary(
        turboThreadID: String,
        workspaceRoot: String
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
            modelID: model?.model ?? preferredModelID,
            effort: .low
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
