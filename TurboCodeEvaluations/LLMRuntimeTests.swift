import Foundation
import FoundationModels
import FoundationModelsUtilities
import Testing
@testable import TurboCode

@MainActor
@Suite("LLM runtime execution ownership")
struct LLMRuntimeTests {
    @Test("Runtime retains and releases one concrete backend session")
    func ownsSessionThroughSettlement() async {
        let runtime = LLMRuntime()
        let turnID = TurnID(rawValue: "llm-runtime-settlement")
        let session = SuspendedBackendSession(backend: .llamaServer)
        let task = Task { @MainActor in
            await runtime.execute(
                request: request(id: turnID, backend: .llamaServer),
                using: session,
                events: .none
            )
        }

        await Task.yield()
        #expect(runtime.hasActiveSession)
        #expect(runtime.ownsSession(for: turnID))

        session.complete(with: .succeeded)
        let result = await task.value

        #expect(result.outcome == .succeeded)
        #expect(!runtime.hasActiveSession)
        #expect(!runtime.ownsSession(for: turnID))
    }

    @Test("Runtime interruption targets the owning turn and waits for unwind")
    func interruptsOnlyOwningSession() async {
        let runtime = LLMRuntime()
        let turnID = TurnID(rawValue: "llm-runtime-interrupt")
        let session = SuspendedBackendSession(backend: .codex)
        let task = Task { @MainActor in
            await runtime.execute(
                request: request(id: turnID, backend: .codex),
                using: session,
                events: .none
            )
        }

        await Task.yield()
        await runtime.interrupt(turnID: TurnID(rawValue: "stale-turn"))
        #expect(!session.wasInterrupted)
        #expect(runtime.hasActiveSession)

        await runtime.interrupt(turnID: turnID)
        #expect(session.wasInterrupted)
        // `interrupt` resolves the adapter's run, after which `execute` owns
        // the final release. The UI cannot clear this state independently.
        let result = await task.value
        #expect(result.outcome == .cancelled(reason: "Interrupted by test."))
        #expect(!runtime.hasActiveSession)
    }

    @Test("Runtime rejects competing and mismatched backend sessions")
    func rejectsInvalidExecutionAdmission() async {
        let runtime = LLMRuntime()
        let activeID = TurnID(rawValue: "llm-runtime-active")
        let activeSession = SuspendedBackendSession(backend: .foundationApple)
        let activeTask = Task { @MainActor in
            await runtime.execute(
                request: request(id: activeID, backend: .foundationApple),
                using: activeSession,
                events: .none
            )
        }
        await Task.yield()

        let competing = await runtime.execute(
            request: request(
                id: TurnID(rawValue: "llm-runtime-competing"),
                backend: .foundationApple
            ),
            using: CompletingBackendSession(backend: .foundationApple),
            events: .none
        )
        #expect(failureCode(in: competing) == "llm_runtime.busy")

        activeSession.complete(with: .succeeded)
        _ = await activeTask.value

        let mismatch = await runtime.execute(
            request: request(
                id: TurnID(rawValue: "llm-runtime-mismatch"),
                backend: .llamaServer
            ),
            using: CompletingBackendSession(backend: .foundationApple),
            events: .none
        )
        #expect(failureCode(in: mismatch) == "llm_runtime.backend_mismatch")
        #expect(!runtime.hasActiveSession)
    }

    @Test("Runtime factory builds providers and records Codex failure state")
    func buildsAdaptersBehindRuntimeBoundary() async {
        let codexFailure = TurnFailure(
            code: "codex.authentication",
            message: "Codex authentication is required.",
            isRecoverable: true
        )
        let factory = RecordingBackendSessionFactory(
            nativeSession: CompletingBackendSession(
                backend: .llamaServer,
                outcome: .succeeded
            ),
            codexSession: CompletingBackendSession(
                backend: .codex,
                outcome: .failed(codexFailure)
            )
        )
        let runtime = LLMRuntime(
            sessionFactory: factory,
            foundationModelsBootstrap: FoundationModelsBootstrapConfiguration(
                backend: .llamaServer,
                usesSystemModel: true,
                remoteModel: .fallbackLlama
            )
        )

        let native = await runtime.executeNative(
            request: request(
                id: TurnID(rawValue: "factory-native"),
                backend: .llamaServer
            ),
            configuration: NativeLLMExecutionConfiguration(
                mode: .standalone,
                workspaceKind: "test",
                serverURL: nil,
                diagnosticsChanged: { _ in },
                contextChanged: { _ in },
                approvalRequested: { _ in }
            ),
            events: .none
        )
        let codex = await runtime.executeCodex(
            request: request(
                id: TurnID(rawValue: "factory-codex"),
                backend: .codex
            ),
            configuration: CodexLLMExecutionConfiguration(
                turboThreadID: "thread-test",
                workspaceName: "Fixture",
                agentTuning: AgentTuningConfig(),
                availableSkills: [],
                modelID: nil,
                reasoningEffort: nil,
                delegationInvoker: nil,
                activityStarted: { _, _ in },
                activityEnded: { _ in },
                presentationRequested: { _ in },
                approvalRequested: { _ in }
            ),
            events: .none
        )

        #expect(native.outcome == .succeeded)
        #expect(codex.outcome == .failed(codexFailure))
        #expect(factory.nativeBuildCount == 1)
        #expect(factory.codexBuildCount == 1)
        #expect(factory.recordedCodexFailure == codexFailure)
    }

    @Test("Runtime owns Foundation Models rebuild and lends one session generation")
    func ownsFoundationModelsSessionGeneration() async throws {
        let factory = RecordingBackendSessionFactory(
            nativeSession: CompletingBackendSession(backend: .llamaServer),
            codexSession: CompletingBackendSession(backend: .codex)
        )
        let runtime = LLMRuntime(
            sessionFactory: factory,
            foundationModelsBootstrap: FoundationModelsBootstrapConfiguration(
                backend: .llamaServer,
                usesSystemModel: true,
                remoteModel: .fallbackLlama
            )
        )

        _ = await runtime.executeNative(
            request: request(
                id: TurnID(rawValue: "foundation-generation-first"),
                backend: .llamaServer
            ),
            configuration: nativeConfiguration,
            events: .none
        )
        let firstSession = try #require(factory.nativeProviderSessions.last)
        let firstRelay = try #require(factory.nativeReasoningRelays.last ?? nil)

        #expect(runtime.rebuildFoundationModelsSession(
            configuration: Self.llamaSessionConfiguration,
            keepingHistory: false,
            events: Self.noopModelSessionEvents
        ))
        _ = await runtime.executeNative(
            request: request(
                id: TurnID(rawValue: "foundation-generation-second"),
                backend: .llamaServer
            ),
            configuration: nativeConfiguration,
            events: .none
        )
        let secondSession = try #require(factory.nativeProviderSessions.last)
        let secondRelay = try #require(factory.nativeReasoningRelays.last ?? nil)

        #expect(firstSession !== secondSession)
        #expect(firstRelay !== secondRelay)
        #expect(runtime.foundationModelsTranscript != nil)
    }

    @Test("Runtime rejects Foundation Models rebuild while an adapter is active")
    func rejectsFoundationModelsRebuildDuringExecution() async {
        let suspended = SuspendedBackendSession(backend: .llamaServer)
        let factory = RecordingBackendSessionFactory(
            nativeSession: suspended,
            codexSession: CompletingBackendSession(backend: .codex)
        )
        let runtime = LLMRuntime(
            sessionFactory: factory,
            foundationModelsBootstrap: FoundationModelsBootstrapConfiguration(
                backend: .llamaServer,
                usesSystemModel: true,
                remoteModel: .fallbackLlama
            )
        )
        let turnID = TurnID(rawValue: "foundation-rebuild-active")
        let task = Task { @MainActor in
            await runtime.executeNative(
                request: request(id: turnID, backend: .llamaServer),
                configuration: nativeConfiguration,
                events: .none
            )
        }
        await Task.yield()

        #expect(!runtime.rebuildFoundationModelsSession(
            configuration: Self.llamaSessionConfiguration,
            keepingHistory: false,
            events: Self.noopModelSessionEvents
        ))

        suspended.complete(with: .succeeded)
        _ = await task.value
    }

    private var nativeConfiguration: NativeLLMExecutionConfiguration {
        NativeLLMExecutionConfiguration(
            mode: .standalone,
            workspaceKind: "test",
            serverURL: nil,
            diagnosticsChanged: { _ in },
            contextChanged: { _ in },
            approvalRequested: { _ in }
        )
    }

    private static var noopModelSessionEvents: ModelSessionEvents {
        ModelSessionEvents(
            toolStarted: { _, _, _ in },
            toolFinished: { _, _, _, _ in },
            delegationChanged: { _ in }
        )
    }

    private static var llamaSessionConfiguration: ModelSessionConfiguration {
        ModelSessionConfiguration(
            backend: .llamaServer,
            activeRemoteModel: nil,
            delegateRemoteModel: .fallbackLlama,
            orchestratorMode: .standalone,
            workspaceRoot: FileManager.default.temporaryDirectory.path,
            agentTuning: .default,
            availableSkills: [],
            activeDynamicProfile: nil,
            reasoningEffort: nil,
            delegateReasoningEffort: nil,
            activeTemperature: nil,
            delegateTemperature: nil,
            delegateToolIDs: nil,
            dropsCompletedToolCalls: true,
            workspaceInstructions: nil
        )
    }

    private func request(id: TurnID, backend: ModelBackend) -> TurnRequest {
        TurnRequest(
            id: id,
            prompt: "Exercise the LLM runtime boundary.",
            backend: backend,
            modelName: "Configured test model",
            workspaceRoot: "/workspace"
        )
    }

    private func failureCode(in result: BackendSessionResult) -> String? {
        guard case .failed(let failure) = result.outcome else { return nil }
        return failure.code
    }
}

@MainActor
private final class SuspendedBackendSession: BackendSession {
    let backend: ModelBackend
    private var continuation: CheckedContinuation<BackendSessionResult, Never>?
    private(set) var wasInterrupted = false

    init(backend: ModelBackend) {
        self.backend = backend
    }

    func run(
        request: TurnRequest,
        events: BackendSessionEvents
    ) async -> BackendSessionResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func interrupt() async {
        wasInterrupted = true
        complete(with: .cancelled(reason: "Interrupted by test."))
    }

    func complete(with outcome: TurnOutcome) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(
            returning: BackendSessionResult(outcome: outcome)
        )
    }
}

@MainActor
private final class CompletingBackendSession: BackendSession {
    let backend: ModelBackend
    let outcome: TurnOutcome

    init(backend: ModelBackend, outcome: TurnOutcome = .succeeded) {
        self.backend = backend
        self.outcome = outcome
    }

    func run(
        request: TurnRequest,
        events: BackendSessionEvents
    ) async -> BackendSessionResult {
        BackendSessionResult(outcome: outcome)
    }

    func interrupt() async {}
}

@MainActor
private final class RecordingBackendSessionFactory: LLMBackendSessionBuilding {
    let nativeSession: any BackendSession
    let codexSession: any BackendSession
    private(set) var nativeBuildCount = 0
    private(set) var codexBuildCount = 0
    private(set) var recordedCodexFailure: TurnFailure?
    private(set) var nativeProviderSessions: [LanguageModelSession] = []
    private(set) var nativeReasoningRelays: [ReasoningStreamRelay?] = []

    init(
        nativeSession: any BackendSession,
        codexSession: any BackendSession
    ) {
        self.nativeSession = nativeSession
        self.codexSession = codexSession
    }

    func makeNativeSession(
        request: TurnRequest,
        configuration: NativeLLMExecutionConfiguration,
        session: LanguageModelSession,
        reasoningStreamRelay: ReasoningStreamRelay?
    ) -> any BackendSession {
        nativeBuildCount += 1
        nativeProviderSessions.append(session)
        nativeReasoningRelays.append(reasoningStreamRelay)
        return nativeSession
    }

    func makeCodexSession(
        request: TurnRequest,
        configuration: CodexLLMExecutionConfiguration
    ) -> any BackendSession {
        codexBuildCount += 1
        return codexSession
    }

    func recordCodexFailure(_ failure: TurnFailure) {
        recordedCodexFailure = failure
    }
}
