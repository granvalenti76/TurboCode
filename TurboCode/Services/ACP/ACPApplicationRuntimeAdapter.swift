import Foundation
import FoundationModels

/// Immutable provider/profile snapshot used by one headless ACP session.
///
/// The snapshot is created by the host's composition root. ACP turns then use
/// the same `LLMRuntime` and `AgentRuntime` as the desktop application without
/// reaching into observable stores or constructing a second model loop.
nonisolated struct ACPHostSessionConfiguration: Sendable {
    let modelConfiguration: ModelSessionConfiguration
    let modelName: String
    let workspaceName: String?
    let serverURL: String?
    let codexModelID: String?
    let codexReasoningEffort: CodexReasoningEffort?
    let selectedModelID: String
    let availableModels: [ACPModelSelection]

    init(
        modelConfiguration: ModelSessionConfiguration,
        modelName: String,
        workspaceName: String?,
        serverURL: String?,
        codexModelID: String?,
        codexReasoningEffort: CodexReasoningEffort?,
        selectedModelID: String? = nil,
        availableModels: [ACPModelSelection] = []
    ) {
        self.modelConfiguration = modelConfiguration
        self.modelName = modelName
        self.workspaceName = workspaceName
        self.serverURL = serverURL
        self.codexModelID = codexModelID
        self.codexReasoningEffort = codexReasoningEffort
        self.selectedModelID = selectedModelID
            ?? modelConfiguration.activeRemoteModel?.id
            ?? modelConfiguration.backend.rawValue
        self.availableModels = availableModels
    }

    var configOptions: [ACPConfigOption] {
        guard !availableModels.isEmpty else { return [] }
        return [
            ACPConfigOption(
                id: "model",
                name: "Modello",
                category: "model",
                currentValue: selectedModelID,
                options: availableModels.map {
                    ACPConfigOptionValue(value: $0.id, name: $0.name)
                }
            )
        ]
    }

    func applying(model: ACPModelSelection) -> Self {
        Self(
            modelConfiguration: model.modelConfiguration,
            modelName: model.modelName,
            workspaceName: model.workspaceName,
            serverURL: model.serverURL,
            codexModelID: model.codexModelID,
            codexReasoningEffort: model.codexReasoningEffort,
            selectedModelID: model.id,
            availableModels: availableModels
        )
    }
}

/// Complete immutable provider snapshot for one ACP model selector value.
/// The provider-facing model name is kept separate from the stable ACP ID.
nonisolated struct ACPModelSelection: Sendable {
    let id: String
    let name: String
    let modelConfiguration: ModelSessionConfiguration
    let modelName: String
    let workspaceName: String?
    let serverURL: String?
    let codexModelID: String?
    let codexReasoningEffort: CodexReasoningEffort?
}

/// Bridges the ACP session driver to TurboCode's existing runtime boundary.
///
/// This type is deliberately UI-free and nonisolated. Mutable session and
/// turn identity live in `SessionState`; provider lifecycle remains owned by
/// the per-session `AgentRuntime`/`LLMRuntime` pair, while
/// `ACPEventProjector` is the only wire projection layer.
nonisolated final class ACPApplicationRuntimeAdapter: ACPApplicationRuntime, @unchecked Sendable {
    private let makeAgentRuntime: @Sendable (ModelBackend) -> AgentRuntime
    private let makeLLMRuntime: @MainActor @Sendable (
        ACPHostSessionConfiguration
    ) -> LLMRuntime
    private let makeConfiguration: @MainActor @Sendable (
        String
    ) -> ACPHostSessionConfiguration
    private let projector: ACPEventProjector
    private let state = SessionState()

    init(
        agentRuntime: AgentRuntime,
        llmRuntime: LLMRuntime,
        makeConfiguration: @escaping @MainActor @Sendable (
            String
        ) -> ACPHostSessionConfiguration,
        projector: ACPEventProjector = ACPEventProjector()
    ) {
        // Kept for focused single-session fixtures. Production composition
        // uses the factory initializer below so sessions cannot share state.
        self.makeAgentRuntime = { _ in agentRuntime }
        self.makeLLMRuntime = { _ in llmRuntime }
        self.makeConfiguration = makeConfiguration
        self.projector = projector
    }

    init(
        agentRuntime: AgentRuntime,
        makeLLMRuntime: @escaping @MainActor @Sendable (
            ACPHostSessionConfiguration
        ) -> LLMRuntime,
        makeConfiguration: @escaping @MainActor @Sendable (
            String
        ) -> ACPHostSessionConfiguration,
        projector: ACPEventProjector = ACPEventProjector()
    ) {
        // Kept for focused single-session fixtures. Production composition
        // uses the factory initializer below so sessions cannot share state.
        self.makeAgentRuntime = { _ in agentRuntime }
        self.makeLLMRuntime = makeLLMRuntime
        self.makeConfiguration = makeConfiguration
        self.projector = projector
    }

    init(
        makeAgentRuntime: @escaping @Sendable (ModelBackend) -> AgentRuntime,
        makeLLMRuntime: @escaping @MainActor @Sendable (
            ACPHostSessionConfiguration
        ) -> LLMRuntime,
        makeConfiguration: @escaping @MainActor @Sendable (
            String
        ) -> ACPHostSessionConfiguration,
        projector: ACPEventProjector = ACPEventProjector()
    ) {
        self.makeAgentRuntime = makeAgentRuntime
        self.makeLLMRuntime = makeLLMRuntime
        self.makeConfiguration = makeConfiguration
        self.projector = projector
    }

    func prepareSession(
        sessionID: String,
        cwd: String,
        mcpServers: [MCPJSONValue]
    ) async throws {
        let configuration = await makeConfiguration(cwd)
        let agentRuntime = makeAgentRuntime(
            configuration.modelConfiguration.backend
        )
        let llmRuntime = await makeLLMRuntime(configuration)
        let mcpRuntime = ACPMCPRuntime()
        guard await state.beginPreparation(
            sessionID: sessionID,
            mcpRuntime: mcpRuntime
        ) else {
            throw ACPApplicationRuntimeError.executionFailed(
                "The ACP runtime is shutting down."
            )
        }
        let mcpTools: [any Tool]
        do {
            mcpTools = try await mcpRuntime.start(
                declarations: mcpServers,
                cwd: cwd
            )
            guard !Task.isCancelled else { throw CancellationError() }
            guard await state.insert(
                sessionID: sessionID,
                cwd: cwd,
                configuration: configuration,
                agentRuntime: agentRuntime,
                llmRuntime: llmRuntime,
                mcpRuntime: mcpRuntime,
                mcpTools: mcpTools,
                eventRouter: ACPSessionEventRouter(sessionID: sessionID)
            ) else {
                throw ACPApplicationRuntimeError.executionFailed(
                    "The ACP runtime is shutting down."
                )
            }
            await state.finishPreparation(sessionID: sessionID)
            return
        } catch {
            await state.finishPreparation(sessionID: sessionID)
            await mcpRuntime.stop()
            throw error
        }
    }

    func shutdown() async {
        let turnIDs = await state.shutdown()
        for turnID in turnIDs {
            await projector.finish(turnID: turnID)
        }
    }

    func run(
        turn: ACPApplicationTurn,
        updates: ACPUpdateChannel
    ) async throws -> ACPStopReason {
        try await run(
            turn: turn,
            updates: updates,
            requestPermission: { _ in .reject }
        )
    }

    func run(
        turn: ACPApplicationTurn,
        updates: ACPUpdateChannel,
        requestPermission: @escaping ACPPermissionHandler
    ) async throws -> ACPStopReason {
        guard await state.contains(sessionID: turn.sessionID) else {
            throw ACPApplicationRuntimeError.sessionNotFound(turn.sessionID)
        }
        guard let context = await state.begin(
            sessionID: turn.sessionID,
            turnID: turn.turnID
        ) else {
            throw ACPApplicationRuntimeError.executionFailed(
                "The ACP session already has an active turn."
            )
        }
        let configuration = context.configuration
        let agentRuntime = context.agentRuntime
        let llmRuntime = context.llmRuntime
        await context.eventRouter.install(
            turnID: turn.turnID,
            events: BackendSessionEvents { [agentRuntime, projector] event in
                // Backend adapters emit `.completed` as a provider lifecycle
                // notification, but ACP owns terminal settlement after
                // `LLMRuntime` has released the provider operation. Applying
                // that event here would try to jump from `.streaming` directly
                // to `.completed` and would let a stale callback close a newer
                // turn.
                guard case .completed = event else {
                    guard await agentRuntime.apply(event) else { return }
                    if let update = await projector.update(
                        for: event,
                        sessionID: turn.sessionID
                    ) {
                        updates.emit(update)
                    }
                    return
                }
            },
            requestPermission: requestPermission
        )
        var runtimeStarted = false
        do {
            let prompt = try Self.promptText(from: turn.prompt)
            let request = TurnRequest(
                id: turn.turnID,
                prompt: prompt,
                backend: configuration.modelConfiguration.backend,
                modelName: configuration.modelName,
                workspaceRoot: turn.cwd
            )
            guard await agentRuntime.apply(.started(request)) else {
                throw ACPApplicationRuntimeError.executionFailed(
                    "The runtime rejected the ACP turn."
                )
            }
            guard await agentRuntime.advance(
                to: .preparing,
                turnID: turn.turnID
            ) else {
                throw ACPApplicationRuntimeError.executionFailed(
                    "The runtime could not prepare the ACP turn."
                )
            }
            runtimeStarted = true

            let resultBox = ResultBox()
            let events = context.eventRouter.backendEvents
            let modelEvents = Self.modelSessionEvents(
                sessionID: turn.sessionID,
                eventRouter: context.eventRouter,
                additionalTools: context.mcpTools
            )
            let admitted = await agentRuntime.runOperation(turnID: turn.turnID) {
                let result: BackendSessionResult
                switch configuration.modelConfiguration.backend {
                case .codex:
                    result = await llmRuntime.executeCodex(
                        request: request,
                        configuration: Self.codexConfiguration(
                            sessionID: turn.sessionID,
                            configuration: configuration,
                            requestPermission: requestPermission
                        ),
                        events: events
                    )
                default:
                    if context.needsRebuild {
                        let rebuilt = await llmRuntime.rebuildFoundationModelsSession(
                            configuration: configuration.modelConfiguration,
                            events: modelEvents
                        )
                        guard rebuilt else {
                            await resultBox.store(
                                BackendSessionResult(
                                    outcome: .failed(
                                        TurnFailure(
                                            code: "acp.runtime.busy",
                                            message: "The provider session is busy."
                                        )
                                    )
                                )
                            )
                            return
                        }
                        await self.state.markRuntimeConfiguration(
                            sessionID: turn.sessionID,
                            turnID: turn.turnID,
                            selectedModelID: configuration.selectedModelID
                        )
                    }
                    result = await llmRuntime.executeNative(
                        request: request,
                        configuration: Self.nativeConfiguration(
                            sessionID: turn.sessionID,
                            configuration: configuration,
                            events: events,
                            turnID: turn.turnID
                        ),
                        events: events
                    )
                }
                await resultBox.store(result)
            }
            guard admitted, let result = await resultBox.value else {
                throw ACPApplicationRuntimeError.executionFailed(
                    "The runtime could not admit the ACP turn."
                )
            }

            // Cancellation may be requested while the provider is unwinding.
            // Prefer the terminal outcome already recorded for this turn so a
            // late successful result cannot resurrect it.
            let currentState = await agentRuntime.currentTurnState
            let outcome = currentState?.id == turn.turnID
                ? currentState?.outcome ?? result.outcome
                : result.outcome
            try await finish(
                turn: turn,
                outcome: outcome,
                agentRuntime: agentRuntime,
                eventRouter: context.eventRouter
            )
            switch outcome {
            case .succeeded:
                return .endTurn
            case .cancelled:
                return .cancelled
            case .failed(let failure):
                throw ACPApplicationRuntimeError.executionFailed(failure.message)
            }
        } catch {
            if runtimeStarted {
                _ = await agentRuntime.finish(
                    with: .failed(
                        TurnFailure(
                            code: "acp.runtime.lifecycle",
                            message: error.localizedDescription,
                            isRecoverable: true
                        )
                    ),
                    turnID: turn.turnID
                )
            }
            await release(turn: turn, eventRouter: context.eventRouter)
            throw error
        }
    }

    private func finish(
        turn: ACPApplicationTurn,
        outcome: TurnOutcome,
        agentRuntime: AgentRuntime,
        eventRouter: ACPSessionEventRouter
    ) async throws {
        if let current = await agentRuntime.currentTurnState,
           current.id == turn.turnID,
           let currentOutcome = current.outcome {
            guard currentOutcome == outcome else {
                throw ACPApplicationRuntimeError.executionFailed(
                    "The ACP turn has already finished with another outcome."
                )
            }
            await release(turn: turn, eventRouter: eventRouter)
            return
        }
        if case .succeeded = outcome {
            guard await agentRuntime.advance(
                to: .settling,
                turnID: turn.turnID
            ) else {
                throw ACPApplicationRuntimeError.executionFailed(
                    "The runtime could not settle the ACP turn."
                )
            }
        }
        guard await agentRuntime.finish(with: outcome, turnID: turn.turnID) else {
            throw ACPApplicationRuntimeError.executionFailed(
                "The runtime rejected terminal settlement for the ACP turn."
            )
        }
        await release(turn: turn, eventRouter: eventRouter)
    }

    /// Releases only the session turn captured by this request. The identity
    /// guard is essential when cancellation or a late provider callback races
    /// with the next prompt on the same ACP session.
    private func release(
        turn: ACPApplicationTurn,
        eventRouter: ACPSessionEventRouter
    ) async {
        await eventRouter.clear(turnID: turn.turnID)
        await state.finish(
            sessionID: turn.sessionID,
            turnID: turn.turnID
        )
        await projector.finish(turnID: turn.turnID)
    }

    func cancel(sessionID: String) async {
        guard let active = await state.activeTurn(for: sessionID) else { return }
        await active.llmRuntime.interrupt(turnID: active.turnID)
        await active.agentRuntime.cancelAndWaitForOperation()
        _ = await active.agentRuntime.apply(.cancel(turnID: active.turnID))
        await active.eventRouter.clear(turnID: active.turnID)
        await state.finish(sessionID: sessionID, turnID: active.turnID)
        await projector.finish(turnID: active.turnID)
    }

    func configurationOptions(
        sessionID: String
    ) async throws -> [ACPConfigOption] {
        try await state.configurationOptions(sessionID: sessionID)
    }

    func setConfigurationOption(
        sessionID: String,
        configID: String,
        value: MCPJSONValue
    ) async throws -> [ACPConfigOption] {
        try await state.setConfigurationOption(
            sessionID: sessionID,
            configID: configID,
            value: value
        )
    }

    private static func modelSessionEvents(
        sessionID: String,
        eventRouter: ACPSessionEventRouter,
        additionalTools: [any Tool] = []
    ) -> ModelSessionEvents {
        return ModelSessionEvents(
            currentTurnID: {
                await eventRouter.currentTurnID()
            },
            toolStarted: { call, backend, owner in
                await eventRouter.toolStarted(
                    call,
                    backend: backend,
                    owner: owner
                )
            },
            toolFinished: { call, output, backend, owner in
                await eventRouter.toolFinished(
                    call,
                    output: output,
                    backend: backend,
                    owner: owner
                )
            },
            delegationChanged: { _ in },
            agentActivityChanged: { _ in },
            requestApproval: { pending in
                await eventRouter.requestApproval(pending)
            },
            additionalTools: additionalTools
        )
    }

    private static func nativeConfiguration(
        sessionID: String,
        configuration: ACPHostSessionConfiguration,
        events: BackendSessionEvents,
        turnID: TurnID
    ) -> NativeLLMExecutionConfiguration {
        NativeLLMExecutionConfiguration(
            mode: configuration.modelConfiguration.orchestratorMode,
            workspaceKind: configuration.workspaceName ?? "workspace",
            serverURL: configuration.serverURL,
            diagnosticsChanged: { _ in },
            contextChanged: { usage in
                guard let usage else { return }
                await events.emit(
                    .usageUpdated(
                        turnID: turnID,
                        usage: nil,
                        context: ContextUsage(
                            usedTokens: usage.usedTokens,
                            contextSize: usage.contextSize
                        ),
                        at: Date()
                    )
                )
            },
            approvalRequested: { request in
                await events.emit(
                    .approvalRequested(
                        Approval(
                            id: request.id,
                            turnID: turnID,
                            toolCallID: request.id,
                            operation: request.operation,
                            path: request.path,
                            destination: request.destination,
                            summary: request.summary
                        )
                    )
                )
            }
        )
    }

    private static func codexConfiguration(
        sessionID: String,
        configuration: ACPHostSessionConfiguration,
        requestPermission: @escaping ACPPermissionHandler
    ) -> CodexLLMExecutionConfiguration {
        CodexLLMExecutionConfiguration(
            turboThreadID: "acp-\(sessionID)",
            workspaceName: configuration.workspaceName,
            agentTuning: configuration.modelConfiguration.agentTuning,
            availableSkills: configuration.modelConfiguration.availableSkills,
            pluginTools: configuration.modelConfiguration.activePluginTools,
            modelID: configuration.codexModelID,
            reasoningEffort: configuration.codexReasoningEffort,
            delegationInvoker: nil,
            backgroundTaskSubmission: nil,
            selectedToolIDs: configuration.modelConfiguration.activeDynamicProfile?
                .resolvedToolIDs,
            activityStarted: { _, _ in },
            activityEnded: { _ in },
            approvalRequested: { _ in },
            approvalResolution: { request in
                let outcome = await requestPermission(
                    ACPPermissionRequest(
                        sessionID: sessionID,
                        toolCallID: request.id,
                        title: request.displaySummary,
                        operation: request.operation,
                        path: request.path,
                        destination: request.destination
                    )
                )
                switch outcome {
                case .allow: return .allow
                case .reject: return .reject
                case .cancelled: return .cancelled
                }
            }
        )
    }

    private static func promptText(from prompt: [MCPJSONValue]) throws -> String {
        var parts: [String] = []
        for block in prompt {
            guard let object = block.objectValue,
                  let type = object["type"]?.stringValue else {
                throw ACPApplicationRuntimeError.invalidPrompt(
                    "Every ACP prompt block must contain a type."
                )
            }
            switch type {
            case "text":
                if let text = object["text"]?.stringValue {
                    parts.append(text)
                }
            case "resource_link":
                guard let uri = object["uri"]?.stringValue else {
                    throw ACPApplicationRuntimeError.invalidPrompt(
                        "A resource_link prompt block must contain a URI."
                    )
                }
                let name = object["name"]?.stringValue
                parts.append(
                    name.map { "Reference \($0): \(uri)" }
                        ?? "Reference: \(uri)"
                )
            default:
                throw ACPApplicationRuntimeError.invalidPrompt(
                    "Unsupported ACP prompt content type '\(type)'."
                )
            }
        }
        guard !parts.isEmpty else {
            throw ACPApplicationRuntimeError.invalidPrompt(
                "The ACP prompt must contain text or a resource link."
            )
        }
        return parts.joined(separator: "\n\n")
    }

    private actor ResultBox {
        private var result: BackendSessionResult?

        func store(_ result: BackendSessionResult) {
            self.result = result
        }

        var value: BackendSessionResult? { result }
    }

    /// Keeps the callbacks embedded in a persistent Foundation Models session
    /// pointed at the currently admitted ACP turn. Rebuilding a session just
    /// to refresh a request-scoped closure would discard the provider cache.
    private actor ACPSessionEventRouter {
        private struct Route: Sendable {
            let turnID: TurnID
            let events: BackendSessionEvents
            let requestPermission: ACPPermissionHandler
        }

        private let sessionID: String
        private var route: Route?
        private var startedAt: [String: Date] = [:]

        init(sessionID: String) {
            self.sessionID = sessionID
        }

        nonisolated var backendEvents: BackendSessionEvents {
            BackendSessionEvents { [self] event in
                await self.emit(event)
            }
        }

        func install(
            turnID: TurnID,
            events: BackendSessionEvents,
            requestPermission: @escaping ACPPermissionHandler
        ) {
            route = Route(
                turnID: turnID,
                events: events,
                requestPermission: requestPermission
            )
        }

        func clear(turnID: TurnID) {
            guard route?.turnID == turnID else { return }
            route = nil
            startedAt.removeAll(keepingCapacity: true)
        }

        func currentTurnID() -> TurnID? {
            route?.turnID
        }

        func emit(_ event: AgentRuntimeEvent) async {
            guard let route else { return }
            await route.events.emit(event)
        }

        func toolStarted(
            _ call: Transcript.ToolCall,
            backend: ModelBackend,
            owner: AgentActivityToolOwner
        ) async {
            guard let route else { return }
            startedAt[call.id] = Date()
            await route.events.emit(
                .toolStarted(
                    ToolCall(
                        id: call.id,
                        turnID: route.turnID,
                        name: call.toolName
                    )
                )
            )
        }

        func toolFinished(
            _ call: Transcript.ToolCall,
            output: Transcript.ToolOutput,
            backend: ModelBackend,
            owner: AgentActivityToolOwner
        ) async {
            guard let route else { return }
            let started = startedAt.removeValue(forKey: call.id)
            await route.events.emit(
                .toolFinished(
                    ToolResult(
                        id: call.id,
                        turnID: route.turnID,
                        status: .succeeded,
                        output: Self.outputText(from: output),
                        durationMilliseconds: started.map {
                            max(0, Int(Date().timeIntervalSince($0) * 1_000))
                        }
                    )
                )
            )
        }

        func requestApproval(_ pending: PendingToolApproval) async -> String {
            guard let route else {
                return "Action cancelled."
            }
            await route.events.emit(
                .approvalRequested(
                    Approval(
                        id: pending.id,
                        turnID: route.turnID,
                        toolCallID: pending.id,
                        operation: pending.operation,
                        path: pending.path,
                        destination: pending.destination,
                        summary: pending.summary
                    )
                )
            )
            await ToolApprovalRegistry.shared.registerForExternalHost(pending)
            let outcome = await route.requestPermission(
                ACPPermissionRequest(
                    sessionID: sessionID,
                    toolCallID: pending.id,
                    title: pending.summary,
                    operation: pending.operation,
                    path: pending.path,
                    destination: pending.destination
                )
            )
            switch outcome {
            case .allow:
                return (await ToolApprovalRegistry.shared.approve(id: pending.id)).result
            case .reject, .cancelled:
                return (await ToolApprovalRegistry.shared.reject(id: pending.id)).result
            }
        }

        private static func outputText(from output: Transcript.ToolOutput) -> String {
            output.segments.compactMap { segment -> String? in
                switch segment {
                case .text(let value): value.content
                case .structure(let value): value.content.jsonString
                default: nil
                }
            }.joined()
        }
    }

    private actor SessionState {
        struct TurnContext: Sendable {
            let configuration: ACPHostSessionConfiguration
            let agentRuntime: AgentRuntime
            let llmRuntime: LLMRuntime
            let mcpTools: [any Tool]
            let eventRouter: ACPSessionEventRouter
            let needsRebuild: Bool
        }

        private struct Session: Sendable {
            let cwd: String
            var configuration: ACPHostSessionConfiguration
            let agentRuntime: AgentRuntime
            let llmRuntime: LLMRuntime
            let mcpRuntime: ACPMCPRuntime
            let mcpTools: [any Tool]
            let eventRouter: ACPSessionEventRouter
            var runtimeModelID: String?
            var turnID: TurnID?
        }

        private var sessions: [String: Session] = [:]
        private var preparingMCPRuntimes: [String: ACPMCPRuntime] = [:]
        private var shutdownRequested = false

        func beginPreparation(
            sessionID: String,
            mcpRuntime: ACPMCPRuntime
        ) -> Bool {
            guard !shutdownRequested,
                  sessions[sessionID] == nil,
                  preparingMCPRuntimes[sessionID] == nil else {
                return false
            }
            preparingMCPRuntimes[sessionID] = mcpRuntime
            return true
        }

        func finishPreparation(sessionID: String) {
            preparingMCPRuntimes.removeValue(forKey: sessionID)
        }

        func insert(
            sessionID: String,
            cwd: String,
            configuration: ACPHostSessionConfiguration,
            agentRuntime: AgentRuntime,
            llmRuntime: LLMRuntime,
            mcpRuntime: ACPMCPRuntime,
            mcpTools: [any Tool],
            eventRouter: ACPSessionEventRouter
        ) -> Bool {
            guard !shutdownRequested,
                  sessions[sessionID] == nil else {
                return false
            }
            sessions[sessionID] = Session(
                cwd: cwd,
                configuration: configuration,
                agentRuntime: agentRuntime,
                llmRuntime: llmRuntime,
                mcpRuntime: mcpRuntime,
                mcpTools: mcpTools,
                eventRouter: eventRouter,
                runtimeModelID: nil,
                turnID: nil
            )
            return true
        }

        func begin(sessionID: String, turnID: TurnID) -> TurnContext? {
            guard var session = sessions[sessionID], session.turnID == nil else {
                return nil
            }
            session.turnID = turnID
            sessions[sessionID] = session
            return TurnContext(
                configuration: session.configuration,
                agentRuntime: session.agentRuntime,
                llmRuntime: session.llmRuntime,
                mcpTools: session.mcpTools,
                eventRouter: session.eventRouter,
                needsRebuild: session.configuration.modelConfiguration.backend != .codex
                    && session.runtimeModelID != session.configuration.selectedModelID
            )
        }

        func contains(sessionID: String) -> Bool {
            sessions[sessionID] != nil
        }

        func activeTurn(
            for sessionID: String
        ) -> (
            turnID: TurnID,
            agentRuntime: AgentRuntime,
            llmRuntime: LLMRuntime,
            eventRouter: ACPSessionEventRouter
        )? {
            guard let session = sessions[sessionID], let turnID = session.turnID else {
                return nil
            }
            return (
                turnID,
                session.agentRuntime,
                session.llmRuntime,
                session.eventRouter
            )
        }

        func markRuntimeConfiguration(
            sessionID: String,
            turnID: TurnID,
            selectedModelID: String
        ) {
            guard var session = sessions[sessionID], session.turnID == turnID else {
                return
            }
            guard session.configuration.selectedModelID == selectedModelID else {
                // The selector changed while this turn was unwinding. Leave
                // the old marker in place so the next turn rebuilds safely.
                return
            }
            session.runtimeModelID = selectedModelID
            sessions[sessionID] = session
        }

        func configurationOptions(
            sessionID: String
        ) throws -> [ACPConfigOption] {
            guard let session = sessions[sessionID] else {
                throw ACPApplicationRuntimeError.sessionNotFound(sessionID)
            }
            return session.configuration.configOptions
        }

        func setConfigurationOption(
            sessionID: String,
            configID: String,
            value: MCPJSONValue
        ) throws -> [ACPConfigOption] {
            guard var session = sessions[sessionID] else {
                throw ACPApplicationRuntimeError.sessionNotFound(sessionID)
            }
            guard configID == "model" else {
                throw ACPApplicationRuntimeError.invalidConfiguration(
                    "Unknown ACP configuration option '\(configID)'."
                )
            }
            guard case .string(let modelID) = value,
                  let model = session.configuration.availableModels.first(
                      where: { $0.id == modelID }
                  ) else {
                throw ACPApplicationRuntimeError.invalidConfiguration(
                    "The selected ACP model is not available for this session."
                )
            }
            session.configuration = session.configuration.applying(model: model)
            sessions[sessionID] = session
            return session.configuration.configOptions
        }

        func finish(sessionID: String, turnID: TurnID) {
            guard var session = sessions[sessionID] else { return }
            guard session.turnID == turnID else { return }
            session.turnID = nil
            sessions[sessionID] = session
        }

        /// Stops provider work before discarding session state. A late
        /// preparation cannot be inserted after the shutdown flag is set, and
        /// every active turn remains addressable until its provider operation
        /// has unwound.
        func shutdown() async -> [TurnID] {
            guard !shutdownRequested else { return [] }
            shutdownRequested = true
            let activeSessions = Array(sessions.values)
            let pendingMCPRuntimes = Array(preparingMCPRuntimes.values)
            preparingMCPRuntimes.removeAll()

            var turnIDs: [TurnID] = []
            for session in activeSessions {
                if let turnID = session.turnID {
                    turnIDs.append(turnID)
                    await session.llmRuntime.interrupt(turnID: turnID)
                    await session.agentRuntime.cancelAndWaitForOperation()
                    _ = await session.agentRuntime.apply(.cancel(turnID: turnID))
                    await session.eventRouter.clear(turnID: turnID)
                }
                await session.mcpRuntime.stop()
            }
            for runtime in pendingMCPRuntimes {
                await runtime.stop()
            }
            sessions.removeAll()
            return turnIDs
        }
    }
}

extension ACPApplicationRuntimeAdapter {
    /// Builds the headless graph from external model configuration. This
    /// factory is `MainActor` only because the existing configuration stores
    /// are application-owned; the returned adapter itself has no UI affinity.
    @MainActor
    static func makeDefault() -> ACPApplicationRuntimeAdapter {
        let modelRuntime = ModelRuntimeStore()
        let codexRuntime = CodexRuntimeStore()
        let nativeRunner = NativeResponseRunner()

        return ACPApplicationRuntimeAdapter(
            makeAgentRuntime: { backend in
                AgentRuntime(backend: backend)
            },
            makeLLMRuntime: { configuration in
                // Codex's client, approval table, and active-turn identity are
                // session-owned. Native response execution may share its
                // stateless runner, but its backend factory must not share the
                // Codex runtime store across ACP sessions.
                let sessionCodexRuntime = CodexRuntimeStore()
                let sessionFactory = LiveLLMBackendSessionFactory(
                    nativeRunner: nativeRunner,
                    codexRuntime: sessionCodexRuntime
                )
                return LLMRuntime(
                    sessionFactory: sessionFactory,
                    foundationModelsBootstrap: Self.bootstrapConfiguration(
                        for: configuration
                    )
                )
            },
            makeConfiguration: { root in
                _ = modelRuntime.refreshSkills(
                    force: true,
                    workspaceRoot: root
                )
                let modelConfiguration = modelRuntime.makeSessionConfiguration(
                    workspaceRoot: root
                )
                let workspaceName = URL(fileURLWithPath: root).lastPathComponent
                let currentModelID = modelConfiguration.activeRemoteModel?.id
                    ?? modelConfiguration.backend.rawValue
                let currentSelection = ACPModelSelection(
                    id: currentModelID,
                    name: modelRuntime.composerModel,
                    modelConfiguration: modelConfiguration,
                    modelName: modelRuntime.composerModel,
                    workspaceName: workspaceName,
                    serverURL: modelRuntime.activeRemoteModel?.url,
                    codexModelID: codexRuntime.preferredExecutionModelID,
                    codexReasoningEffort: codexRuntime.reasoningEffort
                )
                var selections = [currentSelection]
                if modelRuntime.orchestratorMode == .standalone,
                   modelRuntime.activeDynamicProfile == nil {
                    for model in modelRuntime.enabledRemoteModels
                        where modelRuntime.isConfigured(model)
                    {
                        guard model.id != currentModelID else { continue }
                        selections.append(
                            ACPModelSelection(
                                id: model.id,
                                name: model.name,
                                modelConfiguration: Self.configuration(
                                    from: modelConfiguration,
                                    model: model
                                ),
                                modelName: model.name,
                                workspaceName: workspaceName,
                                serverURL: model.url,
                                codexModelID: nil,
                                codexReasoningEffort: nil
                            )
                        )
                    }
                }
                return ACPHostSessionConfiguration(
                    modelConfiguration: modelConfiguration,
                    modelName: modelRuntime.composerModel,
                    workspaceName: workspaceName,
                    serverURL: modelRuntime.activeRemoteModel?.url,
                    codexModelID: codexRuntime.preferredExecutionModelID,
                    codexReasoningEffort: codexRuntime.reasoningEffort,
                    selectedModelID: currentModelID,
                    availableModels: selections
                )
            }
        )
    }

    @MainActor
    private static func bootstrapConfiguration(
        for configuration: ACPHostSessionConfiguration
    ) -> FoundationModelsBootstrapConfiguration? {
        guard configuration.modelConfiguration.backend != .codex else {
            return nil
        }
        return FoundationModelsBootstrapConfiguration(
            backend: configuration.modelConfiguration.backend,
            usesSystemModel: configuration.modelConfiguration.backend == .foundationApple,
            remoteModel: configuration.modelConfiguration.activeRemoteModel
                ?? .fallbackLlama,
            reasoningEffort: configuration.modelConfiguration.reasoningEffort
        )
    }

    /// Reuses the session's immutable profile/tool snapshot while replacing
    /// only the active configured provider. ACP never mutates ModelRuntimeStore
    /// or its persisted global selection when a session changes model.
    private static func configuration(
        from base: ModelSessionConfiguration,
        model: RemoteModelConfig
    ) -> ModelSessionConfiguration {
        ModelSessionConfiguration(
            backend: backend(for: model.role),
            activeRemoteModel: model,
            delegateRemoteModel: base.delegateRemoteModel,
            orchestratorMode: base.orchestratorMode,
            workspaceRoot: base.workspaceRoot,
            agentTuning: base.agentTuning,
            availableSkills: base.availableSkills,
            documentationStore: base.documentationStore,
            activeDynamicProfile: base.activeDynamicProfile,
            reasoningEffort: model.supportsReasoning
                ? base.reasoningEffort
                : nil,
            delegateReasoningEffort: base.delegateReasoningEffort,
            activeTemperature: model.temperature,
            delegateTemperature: base.delegateTemperature,
            delegateToolIDs: base.delegateToolIDs,
            delegateWorkers: base.delegateWorkers,
            dropsCompletedToolCalls: base.dropsCompletedToolCalls,
            workspaceInstructions: base.workspaceInstructions,
            activePluginTools: base.activePluginTools
        )
    }

    private static func backend(for role: RemoteModelRole) -> ModelBackend {
        switch role {
        case .local: .llamaServer
        case .pcc: .foundationServe
        case .premium: .premium
        }
    }
}
