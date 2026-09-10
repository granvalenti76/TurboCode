import Foundation

/// ACP's stdio adapter. It serializes protocol output through one injected
/// sink, allowing the executable target and tests to share the dispatcher
/// without ever printing diagnostics on stdout.
actor ACPAgentServer {
    typealias LineWriter = @Sendable (Data) async -> Void

    private let driver: any ACPAgentDriver
    private let writeLine: LineWriter
    private let agentName: String
    private let agentVersion: String
    private var activePrompts: [String: Task<Void, Never>] = [:]

    init(
        driver: any ACPAgentDriver,
        agentName: String = "TurboCode",
        agentVersion: String = "0.1.0",
        writeLine: @escaping LineWriter
    ) {
        self.driver = driver
        self.agentName = agentName
        self.agentVersion = agentVersion
        self.writeLine = writeLine
    }

    /// Receives exactly one newline-delimited JSON-RPC message.
    func receive(_ line: Data) async {
        let message: ACPInboundRequest
        do {
            message = try decodeRequest(line)
        } catch let error as ACPProtocolError {
            await respond(
                to: .null,
                errorCode: error.rpcCode,
                message: error.localizedDescription
            )
            return
        } catch {
            await respond(to: .null, errorCode: -32600, message: error.localizedDescription)
            return
        }

        do {
            guard let method = message.method else {
                throw ACPProtocolError.invalidRequest(
                    "ACP messages from the client must contain a method."
                )
            }
            switch method {
            case "initialize":
                try await initialize(id: message.id, params: message.params)
            case "session/new":
                try await createSession(id: message.id, params: message.params)
            case "session/prompt":
                try await startPrompt(id: message.id, params: message.params)
            case "session/cancel":
                try await cancel(id: message.id, params: message.params)
            default:
                await respond(
                    to: message.id,
                    errorCode: -32601,
                    message: "Method not found: \(method)"
                )
            }
        } catch let error as ACPProtocolError {
            await respond(
                to: message.id,
                errorCode: error.rpcCode,
                message: error.localizedDescription
            )
        } catch {
            await respond(to: message.id, errorCode: -32600, message: error.localizedDescription)
        }
    }

    private func initialize(
        id: ACPRequestID?,
        params: MCPJSONValue?
    ) async throws {
        guard params?.objectValue != nil || params == nil else {
            throw ACPProtocolError.invalidParams("initialize params must be an object.")
        }
        await respond(
            to: id,
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(false),
                    "promptCapabilities": .object([
                        "audio": .bool(false),
                        "embeddedContext": .bool(false),
                        "image": .bool(false)
                    ])
                ]),
                "agentInfo": .object([
                    "name": .string(agentName),
                    "title": .string(agentName),
                    "version": .string(agentVersion)
                ]),
                "authMethods": .array([])
            ])
        )
    }

    private func createSession(
        id: ACPRequestID?,
        params: MCPJSONValue?
    ) async throws {
        guard let object = params?.objectValue,
              let cwd = object["cwd"]?.stringValue,
              !cwd.isEmpty,
              cwd.hasPrefix("/") else {
            throw ACPProtocolError.invalidParams(
                "session/new requires an absolute cwd."
            )
        }
        let mcpServers = object["mcpServers"]?.arrayValue ?? []
        do {
            let sessionID = try await driver.createSession(
                cwd: cwd,
                mcpServers: mcpServers
            )
            await respond(
                to: id,
                result: .object(["sessionId": .string(sessionID)])
            )
        } catch {
            await respond(to: id, errorCode: -32000, message: error.localizedDescription)
        }
    }

    private func startPrompt(
        id: ACPRequestID?,
        params: MCPJSONValue?
    ) async throws {
        guard let id else {
            throw ACPProtocolError.invalidRequest(
                "session/prompt must be a request with an ID."
            )
        }
        guard let object = params?.objectValue,
              let sessionID = object["sessionId"]?.stringValue,
              let prompt = object["prompt"]?.arrayValue else {
            throw ACPProtocolError.invalidParams(
                "session/prompt requires sessionId and prompt."
            )
        }
        try validatePrompt(prompt)
        guard activePrompts[sessionID] == nil else {
            await respond(
                to: id,
                errorCode: -32000,
                message: "A prompt is already active for this session."
            )
            return
        }

        let channel = ACPUpdateChannel()
        let updateTask = Task { [weak self] in
            for await update in channel.stream {
                await self?.sendUpdate(update)
            }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let stopReason = try await driver.prompt(
                    sessionID: sessionID,
                    prompt: prompt,
                    updates: channel
                )
                channel.finish()
                await updateTask.value
                await finishPrompt(
                    sessionID: sessionID,
                    requestID: id,
                    result: .object(["stopReason": .string(stopReason.rawValue)])
                )
            } catch is CancellationError {
                channel.finish()
                await updateTask.value
                await finishPrompt(
                    sessionID: sessionID,
                    requestID: id,
                    result: .object(["stopReason": .string(ACPStopReason.cancelled.rawValue)])
                )
            } catch {
                channel.finish()
                await updateTask.value
                await finishPrompt(
                    sessionID: sessionID,
                    requestID: id,
                    errorMessage: error.localizedDescription
                )
            }
        }
        activePrompts[sessionID] = task
    }

    private func cancel(
        id: ACPRequestID?,
        params: MCPJSONValue?
    ) async throws {
        guard let sessionID = params?.objectValue?["sessionId"]?.stringValue else {
            throw ACPProtocolError.invalidParams("session/cancel requires sessionId.")
        }
        activePrompts[sessionID]?.cancel()
        await driver.cancel(sessionID: sessionID)
        await respond(to: id, result: .null)
    }

    private func sendUpdate(_ update: ACPAgentUpdate) async {
        await send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(update.sessionID),
                "update": update.update
            ])
        ]))
    }

    private func finishPrompt(
        sessionID: String,
        requestID: ACPRequestID,
        result: MCPJSONValue? = nil,
        errorMessage: String? = nil
    ) async {
        activePrompts.removeValue(forKey: sessionID)
        if let errorMessage {
            await respond(to: requestID, errorCode: -32000, message: errorMessage)
        } else {
            await respond(to: requestID, result: result ?? .null)
        }
    }

    private func respond(
        to id: ACPRequestID?,
        result: MCPJSONValue
    ) async {
        guard let id else { return }
        await send(.object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "result": result
        ]))
    }

    private func respond(
        to id: ACPRequestID?,
        errorCode: Int,
        message: String
    ) async {
        guard let id else { return }
        await send(.object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "error": .object([
                "code": .number(Double(errorCode)),
                "message": .string(message)
            ])
        ]))
    }

    private func send(_ value: MCPJSONValue) async {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        await writeLine(data)
    }

    private func validatePrompt(_ prompt: [MCPJSONValue]) throws {
        for block in prompt {
            guard let type = block.objectValue?["type"]?.stringValue else {
                throw ACPProtocolError.invalidParams(
                    "Every prompt content block must contain a type."
                )
            }
            guard type == "text" || type == "resource_link" else {
                throw ACPProtocolError.invalidParams(
                    "Prompt content type '\(type)' is not supported by TurboCode ACP."
                )
            }
        }
    }
}

/// Keeps blocking FileHandle reads outside the actor and feeds complete lines
/// to the same server used by tests and the future `turbocode-acp` executable.
struct ACPStdioServer: Sendable {
    private let server: ACPAgentServer

    init(server: ACPAgentServer) {
        self.server = server
    }

    func run() async {
        var buffer = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                await server.receive(Data(line))
            }
        }
        if !buffer.isEmpty {
            await server.receive(buffer)
        }
    }
}

private struct ACPInboundRequest: Sendable {
    let id: ACPRequestID?
    let method: String?
    let params: MCPJSONValue?
}

nonisolated private func decodeRequest(_ data: Data) throws -> ACPInboundRequest {
    guard let root = try? JSONDecoder().decode(MCPJSONValue.self, from: data),
          let object = root.objectValue,
          object["jsonrpc"]?.stringValue == "2.0" else {
        throw ACPProtocolError.invalidRequest("Expected a JSON-RPC 2.0 object.")
    }
    let id: ACPRequestID?
    if let rawID = object["id"] {
        switch rawID {
        case .number(let raw) where Int(exactly: raw) != nil:
            id = .number(Int(raw))
        case .string(let value):
            id = .string(value)
        case .null:
            id = .null
        default:
            throw ACPProtocolError.invalidRequest(
                "Request ID must be a string or integer."
            )
        }
    } else {
        id = nil
    }
    return ACPInboundRequest(
        id: id,
        method: object["method"]?.stringValue,
        params: object["params"]
    )
}

private extension ACPProtocolError {
    var rpcCode: Int {
        switch self {
        case .invalidRequest: -32600
        case .invalidParams: -32602
        }
    }
}
