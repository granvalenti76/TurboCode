import Foundation
import FoundationModels
import FoundationModelsUtilities
import Testing
@testable import TurboCode

@Suite("ACP runtime driver")
struct ACPRuntimeDriverTests {
    @Test("sessions retain their own workspace and turn identity")
    func sessionIsolation() async throws {
        let runtime = ACPTestApplicationRuntime()
        let driver = ACPRuntimeDriver(runtime: runtime)

        let first = try await driver.createSession(cwd: "/tmp/one", mcpServers: [])
        let second = try await driver.createSession(cwd: "/tmp/two", mcpServers: [])
        _ = try await driver.prompt(sessionID: first, prompt: [], updates: ACPUpdateChannel())
        _ = try await driver.prompt(sessionID: second, prompt: [], updates: ACPUpdateChannel())

        let turns = await runtime.recordedTurns()
        #expect(turns.count == 2)
        #expect(Set(turns.map(\.cwd)) == Set(["/tmp/one", "/tmp/two"]))
        #expect(turns.contains { $0.sessionID == first && $0.cwd == "/tmp/one" })
        #expect(turns.contains { $0.sessionID == second && $0.cwd == "/tmp/two" })
        #expect(turns[0].turnID != turns[1].turnID)
    }

    @Test("unknown sessions fail closed")
    func unknownSession() async {
        let driver = ACPRuntimeDriver(runtime: ACPTestApplicationRuntime())
        do {
            _ = try await driver.prompt(
                sessionID: "missing",
                prompt: [],
                updates: ACPUpdateChannel()
            )
            Issue.record("Expected an unknown ACP session to fail.")
        } catch let error as ACPApplicationRuntimeError {
            #expect(error == .sessionNotFound("missing"))
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }
}

@MainActor
@Suite("ACP application runtime adapter")
struct ACPApplicationRuntimeAdapterTests {
    @Test("three consecutive turns settle and preserve turn ownership")
    func consecutiveTurns() async throws {
        let backendSession = ACPControlledBackendSession()
        let factory = ACPControlledBackendSessionFactory(session: backendSession)
        let llmRuntime = LLMRuntime(
            sessionFactory: factory,
            foundationModelsBootstrap: FoundationModelsBootstrapConfiguration(
                backend: .llamaServer,
                usesSystemModel: true,
                remoteModel: .fallbackLlama
            )
        )
        let agentRuntime = AgentRuntime(backend: .llamaServer)
        let configuration = Self.configuration()
        let adapter = ACPApplicationRuntimeAdapter(
            agentRuntime: agentRuntime,
            llmRuntime: llmRuntime,
            makeConfiguration: { _ in configuration }
        )
        try await adapter.prepareSession(
            sessionID: "session-1",
            cwd: "/tmp/project",
            mcpServers: []
        )

        for index in 1...3 {
            let turn = ACPApplicationTurn(
                sessionID: "session-1",
                turnID: TurnID(rawValue: "turn-\(index)"),
                cwd: "/tmp/project",
                prompt: [.object([
                    "type": .string("text"),
                    "text": .string("prompt-\(index)")
                ])]
            )
            #expect(try await adapter.run(
                turn: turn,
                updates: ACPUpdateChannel()
            ) == .endTurn)
        }

        let requests = await backendSession.requests
        #expect(requests == ["prompt-1", "prompt-2", "prompt-3"])
        #expect(await llmRuntime.foundationModelsRebuildCount == 1)
        #expect(await agentRuntime.currentTurnState?.phase == .completed)
        #expect(await agentRuntime.currentTurnState?.outcome == .succeeded)
    }

    @Test("a provider failure releases the session for the next turn")
    func recoversAfterProviderFailure() async throws {
        let failure = TurnFailure(code: "fixture.provider", message: "Fixture failed.")
        let backendSession = ACPControlledBackendSession(
            outcomes: [.failed(failure), .succeeded]
        )
        let adapter = Self.makeAdapter(session: backendSession)
        try await adapter.prepareSession(
            sessionID: "session-1",
            cwd: "/tmp/project",
            mcpServers: []
        )

        do {
            _ = try await adapter.run(
                turn: Self.turn(id: "failed-turn", prompt: "first"),
                updates: ACPUpdateChannel()
            )
            Issue.record("Expected the fixture provider failure.")
        } catch let error as ACPApplicationRuntimeError {
            #expect(error == .executionFailed("Fixture failed."))
        }
        #expect(try await adapter.run(
            turn: Self.turn(id: "recovered-turn", prompt: "second"),
            updates: ACPUpdateChannel()
        ) == .endTurn)
    }

    @Test("cancellation waits for provider unwind and permits a new turn")
    func recoversAfterCancellation() async throws {
        let backendSession = ACPControlledBackendSession(blockUntilCancelled: true)
        let adapter = Self.makeAdapter(session: backendSession)
        try await adapter.prepareSession(
            sessionID: "session-1",
            cwd: "/tmp/project",
            mcpServers: []
        )
        let running = Task {
            try await adapter.run(
                turn: Self.turn(id: "cancelled-turn", prompt: "cancel me"),
                updates: ACPUpdateChannel()
            )
        }
        while await backendSession.requests.isEmpty {
            await Task.yield()
        }
        await adapter.cancel(sessionID: "session-1")
        #expect(try await running.value == .cancelled)
        #expect(try await adapter.run(
            turn: Self.turn(id: "after-cancel-turn", prompt: "second"),
            updates: ACPUpdateChannel()
        ) == .endTurn)
    }

    @Test("shutdown interrupts and awaits an active provider turn")
    func shutdownAwaitsActiveProviderTurn() async throws {
        let backendSession = ACPControlledBackendSession(blockUntilCancelled: true)
        let adapter = Self.makeAdapter(session: backendSession)
        try await adapter.prepareSession(
            sessionID: "session-1",
            cwd: "/tmp/project",
            mcpServers: []
        )
        let running = Task {
            try await adapter.run(
                turn: Self.turn(id: "shutdown-turn", prompt: "stop on EOF"),
                updates: ACPUpdateChannel()
            )
        }
        while await backendSession.requests.isEmpty {
            await Task.yield()
        }

        await adapter.shutdown()

        #expect(try await running.value == .cancelled)
        #expect(await backendSession.interruptCount == 1)
        await adapter.shutdown()
    }

    @Test("a blocked session does not reject an independent session")
    func concurrentSessionIsolation() async throws {
        let firstSession = ACPControlledBackendSession(blockUntilCancelled: true)
        let secondSession = ACPControlledBackendSession()
        var factoryIndex = 0
        let adapter = ACPApplicationRuntimeAdapter(
            makeAgentRuntime: { backend in
                AgentRuntime(backend: backend)
            },
            makeLLMRuntime: { _ in
                factoryIndex += 1
                let session = factoryIndex == 1 ? firstSession : secondSession
                return LLMRuntime(
                    sessionFactory: ACPControlledBackendSessionFactory(session: session),
                    foundationModelsBootstrap: FoundationModelsBootstrapConfiguration(
                        backend: .llamaServer,
                        usesSystemModel: true,
                        remoteModel: .fallbackLlama
                    )
                )
            },
            makeConfiguration: { _ in Self.configuration() }
        )
        try await adapter.prepareSession(
            sessionID: "session-a",
            cwd: "/tmp/a",
            mcpServers: []
        )
        try await adapter.prepareSession(
            sessionID: "session-b",
            cwd: "/tmp/b",
            mcpServers: []
        )

        let firstTurn = Task {
            try await adapter.run(
                turn: Self.turn(id: "blocked-a", prompt: "first", sessionID: "session-a"),
                updates: ACPUpdateChannel()
            )
        }
        while await firstSession.requests.isEmpty {
            await Task.yield()
        }
        let secondTurn = Task {
            try await adapter.run(
                turn: Self.turn(id: "independent-b", prompt: "second", sessionID: "session-b"),
                updates: ACPUpdateChannel()
            )
        }

        #expect(try await secondTurn.value == .endTurn)
        await adapter.cancel(sessionID: "session-a")
        #expect(try await firstTurn.value == .cancelled)
    }

    @Test("model changes are session-local and apply to the next turn")
    func sessionModelSelection() async throws {
        let configuration = Self.configuration()
        let backendSession = ACPControlledBackendSession()
        let factory = ACPControlledBackendSessionFactory(session: backendSession)
        let llmRuntime = LLMRuntime(
            sessionFactory: factory,
            foundationModelsBootstrap: FoundationModelsBootstrapConfiguration(
                backend: .llamaServer,
                usesSystemModel: true,
                remoteModel: .fallbackLlama
            )
        )
        let adapter = ACPApplicationRuntimeAdapter(
            agentRuntime: AgentRuntime(backend: .llamaServer),
            llmRuntime: llmRuntime,
            makeConfiguration: { _ in configuration }
        )
        try await adapter.prepareSession(
            sessionID: "session-a",
            cwd: "/tmp/a",
            mcpServers: []
        )
        try await adapter.prepareSession(
            sessionID: "session-b",
            cwd: "/tmp/b",
            mcpServers: []
        )

        let initial = try await adapter.configurationOptions(sessionID: "session-a")
        #expect(initial.first?.currentValue == "model-a")
        _ = try await adapter.setConfigurationOption(
            sessionID: "session-a",
            configID: "model",
            value: .string("model-b")
        )
        #expect(try await adapter.run(
            turn: Self.turn(
                id: "model-a-turn-1",
                prompt: "first",
                sessionID: "session-a"
            ),
            updates: ACPUpdateChannel()
        ) == .endTurn)
        _ = try await adapter.setConfigurationOption(
            sessionID: "session-a",
            configID: "model",
            value: .string("model-a")
        )
        #expect(try await adapter.run(
            turn: Self.turn(
                id: "model-a-turn-2",
                prompt: "second",
                sessionID: "session-a"
            ),
            updates: ACPUpdateChannel()
        ) == .endTurn)
        let selectedA = try await adapter.configurationOptions(sessionID: "session-a")
        let selectedB = try await adapter.configurationOptions(sessionID: "session-b")
        #expect(selectedA.first?.currentValue == "model-a")
        #expect(selectedB.first?.currentValue == "model-a")
        #expect(await backendSession.modelNames == ["model-b", "model-a"])
        #expect(await llmRuntime.foundationModelsRebuildCount == 2)
    }

    private static func configuration() -> ACPHostSessionConfiguration {
        let model = RemoteModelConfig.fallbackLlama
        let sessionConfiguration = ModelSessionConfiguration(
            backend: .llamaServer,
            activeRemoteModel: model,
            delegateRemoteModel: model,
            orchestratorMode: .standalone,
            workspaceRoot: "/tmp/project",
            agentTuning: .default,
            availableSkills: [],
            documentationStore: .live,
            activeDynamicProfile: nil,
            reasoningEffort: nil,
            delegateReasoningEffort: nil,
            activeTemperature: model.temperature,
            delegateTemperature: model.temperature,
            delegateToolIDs: nil,
            dropsCompletedToolCalls: true,
            workspaceInstructions: nil
        )
        let selection = ACPModelSelection(
            id: "model-a",
            name: "Fixture A",
            modelConfiguration: sessionConfiguration,
            modelName: "model-a",
            workspaceName: "project",
            serverURL: model.url,
            codexModelID: nil,
            codexReasoningEffort: nil
        )
        let alternate = ACPModelSelection(
            id: "model-b",
            name: "Fixture B",
            modelConfiguration: sessionConfiguration,
            modelName: "model-b",
            workspaceName: "project",
            serverURL: model.url,
            codexModelID: nil,
            codexReasoningEffort: nil
        )
        return ACPHostSessionConfiguration(
            modelConfiguration: sessionConfiguration,
            modelName: "model-a",
            workspaceName: "project",
            serverURL: model.url,
            codexModelID: nil,
            codexReasoningEffort: nil,
            selectedModelID: "model-a",
            availableModels: [selection, alternate]
        )
    }

    private static func makeAdapter(
        session: ACPControlledBackendSession
    ) -> ACPApplicationRuntimeAdapter {
        let factory = ACPControlledBackendSessionFactory(session: session)
        return ACPApplicationRuntimeAdapter(
            agentRuntime: AgentRuntime(backend: .llamaServer),
            llmRuntime: LLMRuntime(
                sessionFactory: factory,
                foundationModelsBootstrap: FoundationModelsBootstrapConfiguration(
                    backend: .llamaServer,
                    usesSystemModel: true,
                    remoteModel: .fallbackLlama
                )
            ),
            makeConfiguration: { _ in Self.configuration() }
        )
    }

    private static func turn(
        id: String,
        prompt: String,
        sessionID: String = "session-1"
    ) -> ACPApplicationTurn {
        ACPApplicationTurn(
            sessionID: sessionID,
            turnID: TurnID(rawValue: id),
            cwd: "/tmp/project",
            prompt: [.object([
                "type": .string("text"),
                "text": .string(prompt)
            ])]
        )
    }

}

@MainActor
private final class ACPControlledBackendSessionFactory: LLMBackendSessionBuilding {
    private let session: ACPControlledBackendSession

    init(session: ACPControlledBackendSession) {
        self.session = session
    }

    func makeNativeSession(
        request: TurnRequest,
        configuration: NativeLLMExecutionConfiguration,
        session: LanguageModelSession,
        reasoningStreamRelay: ReasoningStreamRelay?
    ) async -> any BackendSession {
        self.session
    }

    func makeCodexSession(
        request: TurnRequest,
        configuration: CodexLLMExecutionConfiguration
    ) async -> any BackendSession {
        session
    }

    func recordCodexFailure(_ failure: TurnFailure) {}
}

private actor ACPControlledBackendSession: BackendSession {
    nonisolated let backend: ModelBackend = .llamaServer
    private(set) var requests: [String] = []
    private(set) var modelNames: [String] = []
    private(set) var interruptCount = 0
    private var outcomes: [TurnOutcome]
    private let blockUntilCancelled: Bool
    private var cancellationRequested = false

    init(
        outcomes: [TurnOutcome] = [.succeeded],
        blockUntilCancelled: Bool = false
    ) {
        self.outcomes = outcomes
        self.blockUntilCancelled = blockUntilCancelled
    }

    func run(
        request: TurnRequest,
        events: BackendSessionEvents
    ) async -> BackendSessionResult {
        requests.append(request.prompt)
        modelNames.append(request.modelName)
        await events.emit(
            .phaseChanged(
                turnID: request.id,
                phase: .streaming,
                at: Date()
            )
        )
        if blockUntilCancelled && requests.count == 1 {
            while !cancellationRequested {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return BackendSessionResult(
                outcome: .cancelled(reason: "Fixture cancelled.")
            )
        }
        let outcome = outcomes.isEmpty ? .succeeded : outcomes.removeFirst()
        await events.emit(
            .assistantTextChanged(
                turnID: request.id,
                text: "Reply to \(request.prompt)"
            )
        )
        // This duplicate terminal callback models the live adapters. ACP must
        // ignore it until the runtime operation has been released.
        await events.emit(
            .completed(
                turnID: request.id,
                outcome: outcome,
                at: Date()
            )
        )
        return BackendSessionResult(outcome: outcome)
    }

    func interrupt() async {
        interruptCount += 1
        cancellationRequested = true
    }

    func steer(input: String) async -> BackendSteeringResult {
        .unsupported
    }
}

private actor ACPTestApplicationRuntimeState {
    var turns: [ACPApplicationTurn] = []

    func append(_ turn: ACPApplicationTurn) {
        turns.append(turn)
    }

    func snapshot() -> [ACPApplicationTurn] {
        turns
    }
}

private final class ACPTestApplicationRuntime: ACPApplicationRuntime, @unchecked Sendable {
    private let state = ACPTestApplicationRuntimeState()

    nonisolated func prepareSession(
        sessionID: String,
        cwd: String,
        mcpServers: [MCPJSONValue]
    ) async throws {}

    nonisolated func run(
        turn: ACPApplicationTurn,
        updates: ACPUpdateChannel
    ) async throws -> ACPStopReason {
        await state.append(turn)
        return .endTurn
    }

    nonisolated func cancel(sessionID: String) async {}

    nonisolated func recordedTurns() async -> [ACPApplicationTurn] {
        await state.snapshot()
    }
}
