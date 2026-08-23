import Foundation
import FoundationModels
import FoundationModelsUtilities

/// Provider configuration needed to build one native backend adapter.
///
/// Concrete `LanguageModelSession` and reasoning-relay values are deliberately
/// absent. They are resolved by the runtime factory at the last responsible
/// moment, so presentation code cannot retain session infrastructure.
@MainActor
struct NativeLLMExecutionConfiguration {
    let mode: OrchestratorMode
    let workspaceKind: String
    let serverURL: String?
    let diagnosticsChanged: @MainActor @Sendable (String?) async -> Void
    let contextChanged: @MainActor @Sendable (LlamaContextUsage?) async -> Void
    let approvalRequested: @MainActor @Sendable (ApprovalRequest) async -> Void
}

/// Provider configuration needed to build one Codex backend adapter.
/// Presentation callbacks remain explicit output ports; the factory owns the
/// Codex process adapter and does not leak it back through this value.
@MainActor
struct CodexLLMExecutionConfiguration {
    let turboThreadID: String
    let workspaceName: String?
    let agentTuning: AgentTuningConfig
    let availableSkills: [TurboCodeSkillDefinition]
    let pluginTools: [TypeScriptPluginToolBinding]
    let modelID: String?
    let reasoningEffort: CodexReasoningEffort?
    let delegationInvoker: (any AgentTaskInvoking)?
    let activityStarted: @MainActor @Sendable (
        CodexDynamicToolCall,
        String
    ) async -> Void
    let activityEnded: @MainActor @Sendable (String) async -> Void
    let approvalRequested: @MainActor @Sendable (
        ApprovalRequest
    ) async -> Void
}

/// Builds concrete provider adapters exclusively inside the LLM runtime layer.
/// The protocol keeps construction injectable for characterization tests while
/// preventing `ChatResponseCoordinator` from importing adapter initializers.
@MainActor
protocol LLMBackendSessionBuilding: AnyObject, Sendable {
    func makeNativeSession(
        request: TurnRequest,
        configuration: NativeLLMExecutionConfiguration,
        session: LanguageModelSession,
        reasoningStreamRelay: ReasoningStreamRelay?
    ) async -> any BackendSession

    func makeCodexSession(
        request: TurnRequest,
        configuration: CodexLLMExecutionConfiguration
    ) async -> any BackendSession

    func recordCodexFailure(_ failure: TurnFailure)
}

/// Live factory retaining application provider runners shared across turns.
///
/// The factory does not retain Foundation Models session infrastructure.
/// ``LLMRuntime`` lends the current session generation only while this factory
/// constructs the per-turn adapter, so rebuilding cannot create a second
/// long-lived owner or replace a session that is still unwinding.
@MainActor
final class LiveLLMBackendSessionFactory: LLMBackendSessionBuilding {
    private let nativeRunner: any NativeResponseRunning
    private let codexRuntime: CodexRuntimeStore

    init(
        nativeRunner: any NativeResponseRunning,
        codexRuntime: CodexRuntimeStore
    ) {
        self.nativeRunner = nativeRunner
        self.codexRuntime = codexRuntime
    }

    func makeNativeSession(
        request: TurnRequest,
        configuration: NativeLLMExecutionConfiguration,
        session: LanguageModelSession,
        reasoningStreamRelay: ReasoningStreamRelay?
    ) async -> any BackendSession {
        NativeBackendSession(
            backend: request.backend,
            runner: nativeRunner,
            session: session,
            mode: configuration.mode,
            workspaceKind: configuration.workspaceKind,
            serverURL: configuration.serverURL,
            reasoningStreamRelay: reasoningStreamRelay,
            diagnosticsChanged: configuration.diagnosticsChanged,
            contextChanged: configuration.contextChanged,
            approvalRequested: configuration.approvalRequested
        )
    }

    func makeCodexSession(
        request: TurnRequest,
        configuration: CodexLLMExecutionConfiguration
    ) async -> any BackendSession {
        let persistsModelPreference = configuration.modelID == nil
        return CodexBackendSession(
            runtime: codexRuntime.executionEngine,
            turboThreadID: configuration.turboThreadID,
            workspaceName: configuration.workspaceName,
            agentTuning: configuration.agentTuning,
            availableSkills: configuration.availableSkills,
            pluginTools: configuration.pluginTools,
            modelID: configuration.modelID
                ?? codexRuntime.preferredExecutionModelID,
            reasoningEffort: configuration.reasoningEffort
                ?? codexRuntime.reasoningEffort,
            persistsModelPreference: persistsModelPreference,
            delegationInvoker: configuration.delegationInvoker,
            runtimeSnapshotChanged: { [weak codexRuntime] snapshot, persists in
                codexRuntime?.applyExecutionSnapshot(
                    snapshot,
                    persistsPreference: persists
                )
            },
            activityStarted: configuration.activityStarted,
            activityEnded: configuration.activityEnded,
            approvalRequested: configuration.approvalRequested
        )
    }

    /// Provider connection state belongs beside the Codex transport, not in
    /// the timeline mapper. Authentication failures clear the signed-in state;
    /// other failures retain their diagnostic message for the provider UI.
    func recordCodexFailure(_ failure: TurnFailure) {
        if failure.code == "codex.authentication" {
            codexRuntime.markSignedOut()
        } else {
            codexRuntime.markFailed(failure.message)
        }
    }
}

/// Owns execution of the concrete backend session selected for one LLM turn.
///
/// `AgentRuntime` remains the provider-neutral owner of application operation
/// admission and lifecycle. This service is the lower execution boundary: it
/// retains the active native or Codex adapter until that adapter has completely
/// settled, and it never exposes the adapter to SwiftUI or an observable store.
/// Keeping those roles distinct prevents presentation code from becoming a
/// second cancellation or release authority.
///
/// Actor isolation is the execution lock: admission, cancellation, rebuild,
/// and transcript access are serialized by one owner without introducing a
/// second mutex or permitting presentation code to mutate lifecycle state.
actor LLMRuntime {
    private let sessionFactory: (any LLMBackendSessionBuilding)?
    /// The execution runtime is the sole long-lived owner of the active
    /// Foundation Models session and relay. Factories receive borrowed values
    /// only while constructing the per-turn adapter.
    private let foundationModelsRuntime: FoundationModelsSessionRuntime?
    private var activeTurnID: TurnID?
    private var activeSession: (any BackendSession)?
#if DEBUG
    /// Developer diagnostics use a separate ephemeral model, but still share
    /// the runtime's single-execution gate with production adapters.
    private var diagnosticExecutionActive = false
#endif

    init(
        sessionFactory: (any LLMBackendSessionBuilding)? = nil,
        foundationModelsBootstrap: FoundationModelsBootstrapConfiguration? = nil
    ) {
        self.sessionFactory = sessionFactory
        foundationModelsRuntime = foundationModelsBootstrap.map(
            FoundationModelsSessionRuntime.init(configuration:)
        )
    }

    var hasActiveSession: Bool {
        activeSession != nil
    }

    func ownsSession(for turnID: TurnID) -> Bool {
        activeTurnID == turnID && activeSession != nil
    }

    /// Runs exactly one backend adapter and retains it through terminal
    /// settlement. The caller may prepare presentation before entering this
    /// boundary, but it cannot release or replace the concrete provider session.
    ///
    /// Admission should already have succeeded in `AgentRuntime`. These guards
    /// still fail closed because a wiring regression must not silently replace
    /// a live provider request or execute a request with the wrong adapter.
    func execute(
        request: TurnRequest,
        using session: any BackendSession,
        events: BackendSessionEvents
    ) async -> BackendSessionResult {
        guard activeTurnID == nil, !isDiagnosticExecutionActive else {
            return rejectedResult(
                code: "llm_runtime.busy",
                message: "Another LLM backend session is still active."
            )
        }
        guard session.backend == request.backend else {
            return rejectedResult(
                code: "llm_runtime.backend_mismatch",
                message: "The selected backend session does not match the admitted turn."
            )
        }

        // Reserve the turn before the adapter begins. Provider factories may
        // require an actor hop, and this reservation prevents actor reentrancy
        // from admitting a rebuild or competing request during construction.
        activeTurnID = request.id
        activeSession = session
        defer { releaseSession(for: request.id) }

        return await session.run(request: request, events: events)
    }

    /// Resolves and executes a native adapter entirely inside the runtime
    /// layer. `ChatResponseCoordinator` supplies presentation output ports but
    /// never receives the concrete session or reasoning relay.
    func executeNative(
        request: TurnRequest,
        configuration: NativeLLMExecutionConfiguration,
        events: BackendSessionEvents
    ) async -> BackendSessionResult {
        guard let sessionFactory, let foundationModelsRuntime else {
            return rejectedResult(
                code: "llm_runtime.unconfigured",
                message: "No LLM backend session factory is configured."
            )
        }
        guard reserveTurn(request.id) else {
            return rejectedResult(
                code: "llm_runtime.busy",
                message: "Another LLM backend session is still active."
            )
        }
        defer { releaseSession(for: request.id) }
        let resources = await foundationModelsRuntime.resources(
            for: request.backend
        )
        let session = await sessionFactory.makeNativeSession(
            request: request,
            configuration: configuration,
            session: resources.session,
            reasoningStreamRelay: resources.reasoningRelay
        )
        guard session.backend == request.backend else {
            return rejectedResult(
                code: "llm_runtime.backend_mismatch",
                message: "The selected backend session does not match the admitted turn."
            )
        }
        activeSession = session
        return await session.run(request: request, events: events)
    }

    /// Returns a value checkpoint for persistence without exposing the concrete
    /// session that produced it. Codex owns its rollout separately and callers
    /// intentionally omit this checkpoint for Codex conversations.
    func foundationModelsTranscript() async -> Transcript? {
        guard let foundationModelsRuntime else { return nil }
        return await foundationModelsRuntime.transcript
    }

    /// Replaces Foundation Models session infrastructure only at an
    /// application-controlled transition boundary. History preparation and
    /// relay injection stay beside the concrete session owner rather than in an
    /// observable configuration store.
    @discardableResult
    func rebuildFoundationModelsSession(
        configuration: ModelSessionConfiguration,
        keepingHistory: Bool = true,
        discardingCapabilityContext: Bool = false,
        restoringHistory: [Transcript.Entry]? = nil,
        events: ModelSessionEvents
    ) async -> Bool {
        // A configuration transition may replace the stored generation only
        // after the per-turn adapter has unwound. The adapter retains its own
        // session reference, but rejecting overlap also keeps transcript and
        // relay selection deterministic for the next admitted turn.
        guard activeTurnID == nil,
              !isDiagnosticExecutionActive,
              let foundationModelsRuntime else {
            return false
        }
        let transcript = await foundationModelsRuntime.transcript
        let history = restoringHistory ?? SessionRebuildHistory.prepare(
            transcript,
            keepingHistory: keepingHistory,
            discardingCapabilityContext: discardingCapabilityContext
        )
        await foundationModelsRuntime.rebuild(
            configuration: configuration,
            history: history,
            events: events
        )
        return true
    }

#if DEBUG
    /// Runs the developer editing benchmark behind the same exclusion boundary
    /// as conversational adapters. The diagnostic model is ephemeral and never
    /// becomes the active conversation session or transcript owner.
    func runEditingBenchmark(
        configuration: FoundationModelsBootstrapConfiguration,
        reasoningEffort: ReasoningEffort?
    ) async -> String {
        guard activeTurnID == nil, !diagnosticExecutionActive else {
            return "Benchmark unavailable while another LLM operation is active."
        }
        guard configuration.backend != .codex else {
            return "Codex uses its own App Server evaluation path."
        }

        diagnosticExecutionActive = true
        defer { diagnosticExecutionActive = false }
        let model: any LanguageModel = configuration.usesSystemModel
            ? SystemLanguageModel.default
            : ProviderLanguageModel(
                configuration: configuration.remoteModel,
                credential: configuration.remoteModel.credential,
                reasoningStreamRelay: nil
            )
        let result = await AgentBenchmarkRunner.runSuite(
            backend: configuration.backend,
            model: model,
            reasoningLevel: FoundationModelsReasoningLevel.resolve(
                reasoningEffort
            )
        )
        return result.summary
    }
#endif

    /// Resolves and executes a Codex adapter behind the same ownership gate as
    /// native providers. Provider-specific construction no longer lives in the
    /// presentation coordinator.
    func executeCodex(
        request: TurnRequest,
        configuration: CodexLLMExecutionConfiguration,
        events: BackendSessionEvents
    ) async -> BackendSessionResult {
        guard let sessionFactory else {
            return rejectedResult(
                code: "llm_runtime.unconfigured",
                message: "No LLM backend session factory is configured."
            )
        }
        guard reserveTurn(request.id) else {
            return rejectedResult(
                code: "llm_runtime.busy",
                message: "Another LLM backend session is still active."
            )
        }
        defer { releaseSession(for: request.id) }
        let session = await sessionFactory.makeCodexSession(
            request: request,
            configuration: configuration
        )
        guard session.backend == request.backend else {
            return rejectedResult(
                code: "llm_runtime.backend_mismatch",
                message: "The selected backend session does not match the admitted turn."
            )
        }
        activeSession = session
        let result = await session.run(request: request, events: events)
        if case .failed(let failure) = result.outcome {
            await sessionFactory.recordCodexFailure(failure)
        }
        return result
    }

    /// Interrupts only the adapter owned by the requested turn. Ownership is
    /// released by `execute` after the adapter unwinds, never optimistically at
    /// the moment cancellation is requested.
    func interrupt(turnID: TurnID) async {
        guard ownsSession(for: turnID), let activeSession else { return }
        await activeSession.interrupt()
    }

    private func releaseSession(for turnID: TurnID) {
        guard activeTurnID == turnID else { return }
        activeSession = nil
        activeTurnID = nil
    }

    private func reserveTurn(_ turnID: TurnID) -> Bool {
        guard activeTurnID == nil, !isDiagnosticExecutionActive else {
            return false
        }
        activeTurnID = turnID
        return true
    }

    /// Release builds have no diagnostic execution path, so the shared gate is
    /// a compile-time constant outside developer tooling.
    private var isDiagnosticExecutionActive: Bool {
#if DEBUG
        diagnosticExecutionActive
#else
        false
#endif
    }

    private func rejectedResult(
        code: String,
        message: String
    ) -> BackendSessionResult {
        BackendSessionResult(
            outcome: .failed(
                TurnFailure(code: code, message: message)
            )
        )
    }
}
