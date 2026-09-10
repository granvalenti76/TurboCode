import Foundation
import Testing
@testable import TurboCode

@Suite("ACP agent server")
struct ACPAgentServerTests {
    @Test("initialization advertises only implemented capabilities")
    func initializationContract() async throws {
        let driver = ACPTestDriver()
        let output = ACPTestOutput()
        let server = ACPAgentServer(driver: driver) { data in
            await output.append(data)
        }

        await server.receive(line("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
        """))

        let message = try await output.nextObject()
        #expect(message["id"] == .number(1))
        #expect(message["result"]?.objectValue?["protocolVersion"] == .number(1))
        #expect(
            message["result"]?.objectValue?["agentCapabilities"]?.objectValue?["loadSession"]
                == .bool(false)
        )
    }

    @Test("session creation preserves cwd and MCP server declarations")
    func sessionCreation() async throws {
        let driver = ACPTestDriver()
        let output = ACPTestOutput()
        let server = ACPAgentServer(driver: driver) { data in
            await output.append(data)
        }
        await server.receive(line("""
        {"jsonrpc":"2.0","id":"new","method":"session/new","params":{"cwd":"/tmp/project","mcpServers":[{"name":"xcode"}]}}
        """))

        let message = try await output.nextObject()
        #expect(message["result"]?.objectValue?["sessionId"] == .string("session-1"))
        let created = await driver.createdSessionValue()
        #expect(created?.cwd == "/tmp/project")
        #expect(created?.mcpServers == [.object(["name": .string("xcode")])])
    }

    @Test("prompt emits session updates before its stop response")
    func promptAndUpdate() async throws {
        let driver = ACPTestDriver()
        let output = ACPTestOutput()
        let server = ACPAgentServer(driver: driver) { data in
            await output.append(data)
        }
        await server.receive(line("""
        {"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"session-1","prompt":[{"type":"text","text":"hello"}]}}
        """))

        let messages = try await output.nextObjects(count: 2)
        #expect(messages[0]["method"] == .string("session/update"))
        #expect(messages[0]["params"]?.objectValue?["sessionId"] == .string("session-1"))
        #expect(messages[1]["id"] == .number(1))
        #expect(
            messages[1]["result"]?.objectValue?["stopReason"]
                == .string(ACPStopReason.endTurn.rawValue)
        )
    }

    @Test("cancel propagates to the driver and completes the prompt")
    func cancellation() async throws {
        let driver = ACPTestDriver(blockPrompt: true)
        let output = ACPTestOutput()
        let server = ACPAgentServer(driver: driver) { data in
            await output.append(data)
        }
        await server.receive(line("""
        {"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"session-1","prompt":[]}}
        """))
        await driver.waitUntilPromptStarted()
        _ = try await output.nextObject()
        await server.receive(line("""
        {"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"session-1"}}
        """))

        let message = try await output.nextObject()
        #expect(message["id"] == .number(7))
        #expect(message["result"]?.objectValue?["stopReason"] == .string("cancelled"))
        #expect(await driver.cancelledSessionValue() == "session-1")
    }

    private func line(_ string: String) -> Data {
        Data(string.utf8)
    }
}

private actor ACPTestOutput {
    private var messages: [[String: MCPJSONValue]] = []
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<[[String: MCPJSONValue]], Error>
    }
    private var waiters: [Waiter] = []

    func append(_ data: Data) {
        guard let message = try? JSONDecoder().decode(MCPJSONValue.self, from: data),
              let object = message.objectValue else { return }
        messages.append(object)
        resumeWaitersIfReady()
    }

    func nextObject() async throws -> [String: MCPJSONValue] {
        try await nextObjects(count: 1).first!
    }

    func nextObjects(count: Int) async throws -> [[String: MCPJSONValue]] {
        if messages.count >= count {
            let result = Array(messages.prefix(count))
            messages.removeFirst(count)
            return result
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(count: count, continuation: continuation))
        }
    }

    private func resumeWaitersIfReady() {
        guard !waiters.isEmpty else { return }
        var remaining: [Waiter] = []
        for waiter in waiters {
            if messages.count >= waiter.count {
                let result = Array(messages.prefix(waiter.count))
                messages.removeFirst(waiter.count)
                waiter.continuation.resume(returning: result)
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

private actor ACPTestDriverState {
    struct CreatedSession: Sendable, Equatable {
        let cwd: String
        let mcpServers: [MCPJSONValue]
    }

    private(set) var createdSession: CreatedSession?
    private(set) var cancelledSession: String?
    private var promptStarted = false

    func recordCreatedSession(cwd: String, mcpServers: [MCPJSONValue]) {
        createdSession = CreatedSession(cwd: cwd, mcpServers: mcpServers)
    }

    func markPromptStarted() {
        promptStarted = true
    }

    func recordCancellation(sessionID: String) {
        cancelledSession = sessionID
    }

    func isPromptStarted() -> Bool {
        promptStarted
    }
}

private final class ACPTestDriver: ACPAgentDriver, @unchecked Sendable {
    private let blockPrompt: Bool
    private let state = ACPTestDriverState()

    nonisolated init(blockPrompt: Bool = false) {
        self.blockPrompt = blockPrompt
    }

    nonisolated func createSession(cwd: String, mcpServers: [MCPJSONValue]) async throws -> String {
        await state.recordCreatedSession(cwd: cwd, mcpServers: mcpServers)
        return "session-1"
    }

    nonisolated func prompt(
        sessionID: String,
        prompt: [MCPJSONValue],
        updates: ACPUpdateChannel
    ) async throws -> ACPStopReason {
        await state.markPromptStarted()
        updates.emit(ACPAgentUpdate(
            sessionID: sessionID,
            update: .object(["sessionUpdate": .string("agent_message_chunk")])
        ))
        if blockPrompt {
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        }
        return .endTurn
    }

    nonisolated func cancel(sessionID: String) async {
        await state.recordCancellation(sessionID: sessionID)
    }

    nonisolated func createdSessionValue() async -> ACPTestDriverState.CreatedSession? {
        await state.createdSession
    }

    nonisolated func cancelledSessionValue() async -> String? {
        await state.cancelledSession
    }

    nonisolated func waitUntilPromptStarted() async {
        while !(await state.isPromptStarted()) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
