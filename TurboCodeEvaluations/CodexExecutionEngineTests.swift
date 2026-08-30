import Foundation
import Testing
@testable import TurboCode

@Suite("Codex execution engine ownership")
struct CodexExecutionEngineTests {
    @Test("Compatible turns reuse one hidden App Server thread")
    func compatibleTurnsReuseThread() async throws {
        let transport = RecordingCodexTransport()
        let engine = CodexExecutionEngine(client: transport)

        _ = try await engine.runTurn(request: request(), events: .none)
        _ = try await engine.runTurn(request: request(), events: .none)

        #expect(await transport.threadStartCount == 1)
        #expect(await transport.turnThreadIDs == ["thread-1", "thread-1"])

        await engine.resetThread(turboThreadID: "turbo-thread")
        _ = try await engine.runTurn(request: request(), events: .none)
        #expect(await transport.threadStartCount == 2)
        #expect(await transport.turnThreadIDs.last == "thread-2")
    }

    @Test("Restored context is owned and forwarded by the engine")
    func restoredContextReachesFirstTurn() async throws {
        let transport = RecordingCodexTransport()
        let engine = CodexExecutionEngine(client: transport)
        await engine.restoreImportedContext(
            turboThreadID: "turbo-thread",
            blocks: [
                ChatBlock(kind: .user, text: "Preserve this restored request."),
                ChatBlock(kind: .assistant, text: "Restored response.")
            ]
        )

        _ = try await engine.runTurn(request: request(), events: .none)

        let context = await transport.additionalContexts.last ?? nil
        #expect(context?.contains("Preserve this restored request.") == true)
        #expect(context?.contains("Restored response.") == true)
    }

    @Test("Editorial Codex turns advertise no dynamic workspace tools")
    func editorialTurnsAreToolless() async throws {
        let transport = RecordingCodexTransport()
        let engine = CodexExecutionEngine(client: transport)

        _ = try await engine.runTurn(
            request: request(allowsTools: false),
            events: .none
        )

        #expect(await transport.dynamicToolCounts == [0])
        let instructions = await transport.developerInstructions
        #expect(instructions.count == 1)
        #expect((instructions.first ?? "").contains("Do not call tools"))
    }

    @Test("Approval resolution remains one-shot inside the engine")
    func approvalResolutionIsOneShot() async throws {
        let approval = CodexApprovalRequest(
            rpcID: .integer(7),
            operation: "write",
            path: "App.swift",
            summary: "Write App.swift",
            acceptedResult: .object(["decision": .string("accept")]),
            declinedResult: .object(["decision": .string("decline")])
        )
        let transport = RecordingCodexTransport(events: [
            .approvalRequested(approval),
            .completed(status: "completed", errorMessage: nil)
        ])
        let engine = CodexExecutionEngine(client: transport)

        _ = try await engine.runTurn(request: request(), events: .none)
        #expect(try await engine.resolveApproval(id: "codex-7", approved: true))
        #expect(try await !engine.resolveApproval(id: "codex-7", approved: true))
        #expect(await transport.resolvedApprovalIDs == ["codex-7"])
    }

    private func request(allowsTools: Bool = true) -> CodexTurnRequest {
        CodexTurnRequest(
            turnID: TurnID(rawValue: "engine-turn"),
            turboThreadID: "turbo-thread",
            prompt: "Run the engine test.",
            workspaceRoot: FileManager.default.temporaryDirectory.path,
            workspaceName: "Fixture",
            agentTuning: .default,
            availableSkills: [],
            modelID: CodexAppServerClient.lunaModelID,
            reasoningEffort: .medium,
            persistsModelPreference: true,
            delegationInvoker: nil,
            allowsTools: allowsTools
        )
    }
}

private extension CodexTurnEvents {
    static var none: CodexTurnEvents {
        CodexTurnEvents(
            runtimeSnapshotChanged: { _, _ in },
            liveAssistantChanged: { _ in },
            liveReasoningChanged: { _ in },
            activityStarted: { _, _ in },
            activityEnded: { _ in },
            toolFinished: { _, _, _ in },
            approvalRequested: { _ in }
        )
    }
}

private actor RecordingCodexTransport: CodexAppServerServing {
    private let events: [CodexTurnEvent]
    private(set) var threadStartCount = 0
    private(set) var turnThreadIDs: [String] = []
    private(set) var additionalContexts: [String?] = []
    private(set) var resolvedApprovalIDs: [String] = []
    private(set) var dynamicToolCounts: [Int] = []
    private(set) var developerInstructions: [String] = []

    init(events: [CodexTurnEvent] = [
        .completed(status: "completed", errorMessage: nil)
    ]) {
        self.events = events
    }

    func prepareCodex(
        selectedModelID: String?
    ) async throws -> CodexRuntimeSnapshot {
        let model = CodexModelDescriptor(
            id: selectedModelID ?? CodexAppServerClient.lunaModelID,
            model: selectedModelID ?? CodexAppServerClient.lunaModelID,
            displayName: "Luna",
            description: "Fixture model",
            supportedReasoningEfforts: [
                CodexReasoningOption(
                    reasoningEffort: .medium,
                    description: "Fixture effort"
                )
            ],
            defaultReasoningEffort: .medium
        )
        return CodexRuntimeSnapshot(
            accountEmail: nil,
            planType: "test",
            models: [model],
            selectedModel: model
        )
    }

    func startChatGPTLogin() async throws -> CodexLoginSession {
        CodexLoginSession(
            id: "login",
            authorizationURL: URL(string: "https://example.com")!
        )
    }

    func waitForChatGPTLogin(id: String) async throws {}

    func startThread(
        workspaceRoot: String,
        modelID: String,
        dynamicTools: [CodexDynamicToolSpec],
        developerInstructions: String
    ) async throws -> String {
        threadStartCount += 1
        dynamicToolCounts.append(dynamicTools.count)
        self.developerInstructions.append(developerInstructions)
        return "thread-\(threadStartCount)"
    }

    func startTurn(
        threadID: String,
        text: String,
        workspaceRoot: String,
        modelID: String,
        effort: CodexReasoningEffort,
        additionalApplicationContext: String?
    ) async throws -> AsyncThrowingStream<CodexTurnEvent, any Error> {
        turnThreadIDs.append(threadID)
        additionalContexts.append(additionalApplicationContext)
        let events = self.events
        return AsyncThrowingStream(CodexTurnEvent.self) { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func interruptActiveTurn() async {}

    func resolveApproval(
        _ request: CodexApprovalRequest,
        approved: Bool
    ) async throws {
        resolvedApprovalIDs.append(request.presentationID)
    }

    func resolveToolCall(
        _ call: CodexDynamicToolCall,
        result: CodexDynamicToolResult
    ) async throws {}
}
