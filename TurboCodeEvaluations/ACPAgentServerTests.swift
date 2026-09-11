import Foundation
import Testing
@testable import TurboCode

@Suite("ACP agent server")
struct ACPAgentServerTests {
    @Test("stdio responds and runs prompts while the client keeps stdin open")
    func persistentStdin() async throws {
        let pipe = Pipe()
        let output = ACPTestOutput()
        let server = ACPAgentServer(driver: ACPTestDriver()) { data in
            await output.append(data)
        }
        let reader = Task {
            await ACPStdioServer(server: server).run(input: pipe.fileHandleForReading)
        }
        // A partial message followed by multiple lines exercises framing on
        // the actual pipe, rather than bypassing stdin via server.receive.
        try pipe.fileHandleForWriting.write(contentsOf: Data("{\"jsonrpc\":\"2.0\",\"id\":1,".utf8))
        try pipe.fileHandleForWriting.write(contentsOf: Data("""
        "method":"initialize","params":{"protocolVersion":1}}
        {"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"session-1","prompt":[{"type":"text","text":"caffè"}]}}

        """.utf8))

        // Bound the regression: the old reader only responds after EOF. Close
        // the writer after observing the result so failure cannot hang tests.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await output.messageCount() < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let countBeforeEOF = await output.messageCount()
        try pipe.fileHandleForWriting.close()
        await reader.value
        try pipe.fileHandleForReading.close()
        #expect(countBeforeEOF == 3)
        if countBeforeEOF == 3 {
            let messages = try await output.nextObjects(count: 3)
            #expect(messages[0]["id"] == .number(1))
            #expect(messages[1]["method"] == .string("session/update"))
            #expect(messages[2]["result"]?.objectValue?["stopReason"] == .string("end_turn"))
        }
    }

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

    @Test("session config options advertise and validate per-session model selection")
    func sessionConfigOptions() async throws {
        let driver = ACPTestDriver()
        let output = ACPTestOutput()
        let server = ACPAgentServer(driver: driver) { data in
            await output.append(data)
        }
        await server.receive(line("""
        {"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp/project"}}
        """))
        let created = try await output.nextObject()
        let initialOption = try #require(
            created["result"]?.objectValue?["configOptions"]?.arrayValue?.first?.objectValue
        )
        #expect(initialOption["id"] == .string("model"))
        #expect(initialOption["currentValue"] == .string("model-a"))
        #expect(initialOption["options"]?.arrayValue?.count == 2)

        await server.receive(line("""
        {"jsonrpc":"2.0","id":2,"method":"session/set_config_option","params":{"sessionId":"session-1","configId":"model","value":"model-b"}}
        """))
        let changed = try await output.nextObject()
        #expect(
            changed["result"]?.objectValue?["configOptions"]?.arrayValue?.first?
                .objectValue?["currentValue"] == .string("model-b")
        )

        await server.receive(line("""
        {"jsonrpc":"2.0","id":3,"method":"session/set_config_option","params":{"sessionId":"session-1","configId":"model","value":"missing"}}
        """))
        let rejected = try await output.nextObject()
        #expect(rejected["error"]?.objectValue?["code"] == .number(-32000))
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

    @Test("permission requests use an ACP client response without blocking the dispatcher")
    func permissionRequest() async throws {
        let driver = ACPTestDriver(requestPermission: true)
        let output = ACPTestOutput()
        let server = ACPAgentServer(driver: driver) { data in
            await output.append(data)
        }
        await server.receive(line("""
        {"jsonrpc":"2.0","id":11,"method":"session/prompt","params":{"sessionId":"session-1","prompt":[]}}
        """))

        let permission = try await output.nextObject()
        #expect(permission["method"] == .string("session/request_permission"))
        #expect(
            permission["params"]?.objectValue?["toolCall"]?.objectValue?["toolCallId"]
                == .string("call-1")
        )
        let permissionID = try #require(permission["id"])
        await server.receive(try JSONEncoder().encode(MCPJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": permissionID,
            "result": .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string("allow-once")
                ])
            ])
        ])))

        let completion = try await output.nextObject()
        #expect(completion["id"] == .number(11))
        #expect(
            completion["result"]?.objectValue?["stopReason"]
                == .string(ACPStopReason.endTurn.rawValue)
        )
        #expect(await driver.permissionOutcomeValue() == .allow)
    }

    @Test("permission responses cannot authorize an unoffered option")
    func unofferedPermissionOptionRejects() async throws {
        let driver = ACPTestDriver(requestPermission: true)
        let output = ACPTestOutput()
        let server = ACPAgentServer(driver: driver) { data in
            await output.append(data)
        }
        await server.receive(line("""
        {"jsonrpc":"2.0","id":12,"method":"session/prompt","params":{"sessionId":"session-1","prompt":[]}}
        """))
        let permission = try await output.nextObject()
        let permissionID = try #require(permission["id"])
        await server.receive(try JSONEncoder().encode(MCPJSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": permissionID,
            "result": .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string("allow-always")
                ])
            ])
        ])))

        let completion = try await output.nextObject()
        #expect(
            completion["result"]?.objectValue?["stopReason"]
                == .string(ACPStopReason.refusal.rawValue)
        )
        #expect(await driver.permissionOutcomeValue() == .reject)
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

    func messageCount() -> Int { messages.count }

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
    private(set) var permissionOutcome: ACPPermissionOutcome?
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

    func recordPermissionOutcome(_ outcome: ACPPermissionOutcome) {
        permissionOutcome = outcome
    }

    func isPromptStarted() -> Bool {
        promptStarted
    }
}

private final class ACPTestDriver: ACPAgentDriver, @unchecked Sendable {
    private let blockPrompt: Bool
    private let requestPermission: Bool
    private let state = ACPTestDriverState()

    nonisolated init(blockPrompt: Bool = false, requestPermission: Bool = false) {
        self.blockPrompt = blockPrompt
        self.requestPermission = requestPermission
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

    nonisolated func prompt(
        sessionID: String,
        prompt: [MCPJSONValue],
        updates: ACPUpdateChannel,
        requestPermission: @escaping ACPPermissionHandler
    ) async throws -> ACPStopReason {
        guard self.requestPermission else {
            return try await self.prompt(sessionID: sessionID, prompt: prompt, updates: updates)
        }
        let outcome = await requestPermission(ACPPermissionRequest(
            sessionID: sessionID,
            toolCallID: "call-1",
            title: "Write file",
            operation: "write",
            path: "README.md",
            destination: nil
        ))
        await state.recordPermissionOutcome(outcome)
        return outcome == .allow ? .endTurn : .refusal
    }

    nonisolated func cancel(sessionID: String) async {
        await state.recordCancellation(sessionID: sessionID)
    }

    nonisolated func configurationOptions(
        sessionID: String
    ) async throws -> [ACPConfigOption] {
        Self.options(currentValue: "model-a")
    }

    nonisolated func setConfigurationOption(
        sessionID: String,
        configID: String,
        value: MCPJSONValue
    ) async throws -> [ACPConfigOption] {
        guard configID == "model",
              case .string(let modelID) = value,
              ["model-a", "model-b"].contains(modelID) else {
            throw ACPProtocolError.invalidParams("Unknown model selection.")
        }
        return Self.options(currentValue: modelID)
    }

    private static func options(currentValue: String) -> [ACPConfigOption] {
        [
            ACPConfigOption(
                id: "model",
                name: "Model",
                category: "model",
                currentValue: currentValue,
                options: [
                    ACPConfigOptionValue(value: "model-a", name: "Fixture A"),
                    ACPConfigOptionValue(value: "model-b", name: "Fixture B")
                ]
            )
        ]
    }

    nonisolated func createdSessionValue() async -> ACPTestDriverState.CreatedSession? {
        await state.createdSession
    }

    nonisolated func cancelledSessionValue() async -> String? {
        await state.cancelledSession
    }

    nonisolated func permissionOutcomeValue() async -> ACPPermissionOutcome? {
        await state.permissionOutcome
    }

    nonisolated func waitUntilPromptStarted() async {
        while !(await state.isPromptStarted()) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
