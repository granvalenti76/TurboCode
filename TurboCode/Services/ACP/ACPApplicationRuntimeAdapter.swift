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
}

/// Bridges the ACP session driver to TurboCode's existing runtime boundary.
///
/// This type is deliberately UI-free and nonisolated. Mutable session and
/// turn identity live in `SessionState`; provider lifecycle remains owned by
/// `AgentRuntime`/`LLMRuntime`, while `ACPEventProjector` is the only wire
/// projection layer.
nonisolated final class ACPApplicationRuntimeAdapter: ACPApplicationRuntime, @unchecked Sendable {
    private let agentRuntime: AgentRuntime
    private let llmRuntime: LLMRuntime
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
        self.agentRuntime = agentRuntime
        self.llmRuntime = llmRuntime
        self.makeConfiguration = makeConfiguration
        self.projector = projector
    }

    func prepareSession(
        sessionID: String,
        cwd: String,
        mcpServers: [MCPJSONValue]
    ) async throws {
        let configuration = await makeConfiguration(cwd)
        await state.insert(
            sessionID: sessionID,
            cwd: cwd,
            configuration: configuration
        )
    }

    func run(
        turn: ACPApplicationTurn,
        updates: ACPUpdateChannel
    ) async throws -> ACPStopReason {
        guard let configuration = await state.begin(
            sessionID: turn.sessionID,
            turnID: turn.turnID
        ) else {
            throw ACPApplicationRuntimeError.sessionNotFound(turn.sessionID)
        }
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

            let resultBox = ResultBox()
            let events = BackendSessionEvents { [agentRuntime, projector] event in
                _ = await agentRuntime.apply(event)
                if let update = await projector.update(
                    for: event,
                    sessionID: turn.sessionID
                ) {
                    updates.emit(update)
                }
            }
            let modelEvents = Self.modelSessionEvents(
                turnID: turn.turnID,
                events: events
            )
            let admitted = await agentRuntime.runOperation(turnID: turn.turnID) {
                let result: BackendSessionResult
                switch configuration.modelConfiguration.backend {
                case .codex:
                    result = await self.llmRuntime.executeCodex(
                        request: request,
                        configuration: Self.codexConfiguration(
                            sessionID: turn.sessionID,
                            configuration: configuration
                        ),
                        events: events
                    )
                default:
                    let rebuilt = await self.llmRuntime.rebuildFoundationModelsSession(
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
                    result = await self.llmRuntime.executeNative(
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

            await finish(turn: turn)
            switch result.outcome {
            case .succeeded:
                return .endTurn
            case .cancelled:
                return .cancelled
            case .failed(let failure):
                throw ACPApplicationRuntimeError.executionFailed(failure.message)
            }
        } catch {
            await finish(turn: turn)
            throw error
        }
    }

    private func finish(turn: ACPApplicationTurn) async {
        await state.finish(sessionID: turn.sessionID)
        await projector.finish(turnID: turn.turnID)
    }

    func cancel(sessionID: String) async {
        guard let turnID = await state.turnID(for: sessionID) else { return }
        await llmRuntime.interrupt(turnID: turnID)
        _ = await agentRuntime.apply(.cancel(turnID: turnID))
        await agentRuntime.cancelAndWaitForOperation()
        await state.finish(sessionID: sessionID)
    }

    private static func modelSessionEvents(
        turnID: TurnID,
        events: BackendSessionEvents
    ) -> ModelSessionEvents {
        let tools = ToolEventState()
        return ModelSessionEvents(
            currentTurnID: { turnID },
            toolStarted: { call, _, _ in
                await tools.started(call.id)
                await events.emit(
                    .toolStarted(
                        ToolCall(
                            id: call.id,
                            turnID: turnID,
                            name: call.toolName
                        )
                    )
                )
            },
            toolFinished: { call, output, _, _ in
                let startedAt = await tools.take(call.id)
                let outputText = Self.outputText(from: output)
                await events.emit(
                    .toolFinished(
                        ToolResult(
                            id: call.id,
                            turnID: turnID,
                            status: .succeeded,
                            output: outputText,
                            durationMilliseconds: startedAt.map {
                                max(0, Int(Date().timeIntervalSince($0) * 1_000))
                            }
                        )
                    )
                )
            },
            delegationChanged: { _ in },
            agentActivityChanged: { _ in },
            requestApproval: { pending in
                await events.emit(
                    .approvalRequested(
                        Approval(
                            id: pending.id,
                            turnID: turnID,
                            toolCallID: pending.id,
                            operation: pending.operation,
                            path: pending.path,
                            destination: pending.destination,
                            summary: pending.summary
                        )
                    )
                )
                // ACP permission negotiation is a later protocol slice. A
                // headless process must fail closed instead of waiting on the
                // desktop approval registry, which would never be resolved.
                return "Action denied: ACP permission negotiation is unavailable."
            }
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
        configuration: ACPHostSessionConfiguration
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
            approvalRequested: { _ in }
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

    private static func outputText(from output: Transcript.ToolOutput) -> String {
        output.segments.compactMap { segment -> String? in
            switch segment {
            case .text(let value): value.content
            case .structure(let value): value.content.jsonString
            default: nil
            }
        }.joined()
    }

    private actor ToolEventState {
        private var startedAt: [String: Date] = [:]

        func started(_ id: String) {
            startedAt[id] = Date()
        }

        func take(_ id: String) -> Date? {
            startedAt.removeValue(forKey: id)
        }
    }

    private actor ResultBox {
        private var result: BackendSessionResult?

        func store(_ result: BackendSessionResult) {
            self.result = result
        }

        var value: BackendSessionResult? { result }
    }

    private actor SessionState {
        private struct Session: Sendable {
            let cwd: String
            let configuration: ACPHostSessionConfiguration
            var turnID: TurnID?
        }

        private var sessions: [String: Session] = [:]

        func insert(
            sessionID: String,
            cwd: String,
            configuration: ACPHostSessionConfiguration
        ) {
            sessions[sessionID] = Session(
                cwd: cwd,
                configuration: configuration,
                turnID: nil
            )
        }

        func begin(sessionID: String, turnID: TurnID) -> ACPHostSessionConfiguration? {
            guard var session = sessions[sessionID], session.turnID == nil else {
                return nil
            }
            session.turnID = turnID
            sessions[sessionID] = session
            return session.configuration
        }

        func turnID(for sessionID: String) -> TurnID? {
            sessions[sessionID]?.turnID
        }

        func finish(sessionID: String) {
            guard var session = sessions[sessionID] else { return }
            session.turnID = nil
            sessions[sessionID] = session
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
        let sessionFactory = LiveLLMBackendSessionFactory(
            nativeRunner: nativeRunner,
            codexRuntime: codexRuntime
        )
        let llmRuntime = LLMRuntime(
            sessionFactory: sessionFactory,
            foundationModelsBootstrap:
                modelRuntime.foundationModelsBootstrapConfiguration
        )
        let agentRuntime = AgentRuntime(backend: modelRuntime.activeBackend)

        return ACPApplicationRuntimeAdapter(
            agentRuntime: agentRuntime,
            llmRuntime: llmRuntime,
            makeConfiguration: { root in
                _ = modelRuntime.refreshSkills(
                    force: true,
                    workspaceRoot: root
                )
                let modelConfiguration = modelRuntime.makeSessionConfiguration(
                    workspaceRoot: root
                )
                return ACPHostSessionConfiguration(
                    modelConfiguration: modelConfiguration,
                    modelName: modelRuntime.composerModel,
                    workspaceName: URL(fileURLWithPath: root).lastPathComponent,
                    serverURL: modelRuntime.activeRemoteModel?.url,
                    codexModelID: codexRuntime.preferredExecutionModelID,
                    codexReasoningEffort: codexRuntime.reasoningEffort
                )
            }
        )
    }
}
