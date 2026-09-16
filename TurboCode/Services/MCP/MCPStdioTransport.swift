import Foundation
import FoundationModels

/// Errors at the JSON-RPC transport boundary. A process stop during a tool
/// call is surfaced as a connection failure; callers must not retry a
/// potentially mutating Xcode operation automatically.
nonisolated enum MCPStdioTransportError: LocalizedError, Equatable, Sendable {
    case executableMissing(String)
    case processUnavailable
    case processStopped(String)
    case requestTimedOut(String)
    case invalidResponse(String)
    case rpc(code: Int, message: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            "The MCP executable is not available at \(path)."
        case .processUnavailable:
            "The MCP process is not running."
        case .processStopped(let detail): detail
        case .requestTimedOut(let method):
            "MCP request '\(method)' timed out."
        case .invalidResponse(let detail):
            "MCP returned an invalid response: \(detail)"
        case .rpc(let code, let message):
            "MCP JSON-RPC error \(code): \(message)"
        case .cancelled:
            "The MCP request was cancelled."
        }
    }
}

/// Actor-isolated line-delimited JSON-RPC transport for Xcode's stdio bridge.
/// stdout is reserved for protocol messages and stderr is captured separately
/// for diagnostics, keeping provider and UI layers independent of Process.
actor MCPStdioTransport {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private let workingDirectoryURL: URL?
    private let startupTimeout: Duration
    private let requestTimeout: Duration

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var pending: [Int: CheckedContinuation<MCPJSONValue, any Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var nextRequestID = 1
    private(set) var lastError: String?

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: [String] = ["mcpbridge"],
        environment: [String: String]? = nil,
        workingDirectoryURL: URL? = nil,
        startupTimeout: Duration = .seconds(20),
        requestTimeout: Duration = .seconds(180)
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
    }

    func start(
        protocolVersion: String,
        clientName: String,
        clientVersion: String
    ) async throws {
        guard process?.isRunning != true else { return }
        await stop()
        lastError = nil
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MCPStdioTransportError.executableMissing(executableURL.path)
        }

        let child = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        child.executableURL = executableURL
        child.arguments = arguments
        child.environment = environment
        child.currentDirectoryURL = workingDirectoryURL
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = errorPipe
        do {
            try child.run()
        } catch {
            throw MCPStdioTransportError.processStopped(error.localizedDescription)
        }

        process = child
        inputHandle = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
        readerTask = Task.detached { [weak self, outputHandle] in
            while !Task.isCancelled {
                let data = outputHandle.availableData
                guard !data.isEmpty else {
                    await self?.serverDidStop()
                    return
                }
                await self?.receive(data)
            }
        }
        errorReaderTask = Task.detached { [weak self, errorHandle] in
            while !Task.isCancelled {
                let data = errorHandle.availableData
                guard !data.isEmpty else { return }
                await self?.receiveError(data)
            }
        }

        do {
            _ = try await request(
                method: "initialize",
                params: .object([
                    "protocolVersion": .string(protocolVersion),
                    "capabilities": .object([:]),
                    "clientInfo": .object([
                        "name": .string(clientName),
                        "version": .string(clientVersion)
                    ])
                ]),
                timeout: startupTimeout
            )
            try sendNotification(method: "notifications/initialized")
        } catch {
            await stop()
            throw error
        }
    }

    func request(
        method: String,
        params: MCPJSONValue = .object([:]),
        timeout: Duration? = nil
    ) async throws -> MCPJSONValue {
        guard process?.isRunning == true, inputHandle != nil else {
            throw MCPStdioTransportError.processUnavailable
        }
        if Task.isCancelled { throw MCPStdioTransportError.cancelled }
        let id = nextRequestID
        nextRequestID += 1
        let requestTimeout = timeout ?? self.requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeoutTasks[id] = Task { [weak self] in
                    try? await Task.sleep(for: requestTimeout)
                    guard !Task.isCancelled else { return }
                    await self?.timeout(id: id, method: method)
                }
                do {
                    try send(.object([
                        "jsonrpc": .string("2.0"),
                        "id": .number(Double(id)),
                        "method": .string(method),
                        "params": params
                    ]))
                } catch {
                    timeoutTasks[id]?.cancel()
                    timeoutTasks.removeValue(forKey: id)
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func isRunning() -> Bool {
        process?.isRunning == true
    }

    /// Stops the owned child and waits until it has exited. Closing the pipes
    /// first is required because a fixture or MCP server may otherwise remain
    /// blocked in a read after termination was requested.
    func stop() async {
        let currentProcess = process
        process = nil
        inputHandle?.closeFile()
        inputHandle = nil
        outputHandle?.closeFile()
        outputHandle = nil
        errorHandle?.closeFile()
        errorHandle = nil
        readerTask?.cancel()
        errorReaderTask?.cancel()
        readerTask = nil
        errorReaderTask = nil
        if currentProcess?.isRunning == true {
            currentProcess?.terminate()
            currentProcess?.waitUntilExit()
        }
        let error = MCPStdioTransportError.processStopped(
            lastError ?? "The MCP process stopped."
        )
        failPending(with: error)
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private func cancel(id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        continuation.resume(throwing: MCPStdioTransportError.cancelled)
    }

    private func sendNotification(method: String) throws {
        try send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method)
        ]))
    }

    private func send(_ value: MCPJSONValue) throws {
        guard let inputHandle else {
            throw MCPStdioTransportError.processUnavailable
        }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(MCPJSONValue.self, from: line) else {
                let detail = String(decoding: line, as: UTF8.self)
                lastError = "Malformed JSON-RPC line: \(detail)"
                failPending(with: MCPStdioTransportError.invalidResponse(lastError!))
                continue
            }
            handle(message)
        }
    }

    private func receiveError(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { lastError = text }
    }

    private func handle(_ message: MCPJSONValue) {
        guard let object = message.objectValue,
              let idValue = object["id"],
              case .number(let rawID) = idValue else { return }
        let id = Int(rawID)
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if let error = object["error"]?.objectValue,
           case .number(let rawCode) = error["code"] ?? .null,
           let message = error["message"]?.stringValue {
            continuation.resume(throwing: MCPStdioTransportError.rpc(
                code: Int(rawCode), message: message
            ))
        } else if let result = object["result"] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: MCPStdioTransportError.invalidResponse(
                "JSON-RPC response contained neither result nor error."
            ))
        }
    }

    private func timeout(id: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)
        continuation.resume(throwing: MCPStdioTransportError.requestTimedOut(method))
    }

    private func serverDidStop() {
        guard process != nil else { return }
        let error = MCPStdioTransportError.processStopped(
            lastError ?? "The MCP process stopped unexpectedly."
        )
        process = nil
        inputHandle?.closeFile()
        inputHandle = nil
        outputHandle?.closeFile()
        outputHandle = nil
        errorHandle?.closeFile()
        errorHandle = nil
        failPending(with: error)
        outputBuffer.removeAll(keepingCapacity: false)
    }

    private func failPending(with error: any Error) {
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
    }
}

/// A validated MCP stdio declaration received by one ACP session. It is kept
/// session-local so commands, credentials, and discovered tools never enter
/// persisted application configuration.
nonisolated struct ACPMCPServerConfiguration: Sendable, Equatable {
    let name: String
    let command: String
    let arguments: [String]
    let environment: [String: String]
    let cwd: String

    init(value: MCPJSONValue, cwd: String) throws {
        guard let object = value.objectValue,
              let name = object["name"]?.stringValue,
              !name.isEmpty,
              let command = object["command"]?.stringValue,
              !command.isEmpty else {
            throw ACPApplicationRuntimeError.invalidConfiguration(
                "Each ACP MCP server must contain a non-empty name and command."
            )
        }
        if let transport = object["transport"]?.stringValue,
           transport != "stdio" {
            throw ACPApplicationRuntimeError.invalidConfiguration(
                "ACP MCP server '\(name)' must use the stdio transport."
            )
        }
        let arguments = object["args"]?.arrayValue?.map { $0.stringValue } ?? []
        guard arguments.allSatisfy({ $0 != nil }) else {
            throw ACPApplicationRuntimeError.invalidConfiguration(
                "ACP MCP server '\(name)' has a non-string argument."
            )
        }
        let environment: [String: String]
        if let rawEnvironment = object["env"] {
            guard let entries = rawEnvironment.arrayValue else {
                throw ACPApplicationRuntimeError.invalidConfiguration(
                    "ACP MCP server '\(name)' environment must be an array."
                )
            }
            var parsedEnvironment: [String: String] = [:]
            for entry in entries {
                guard let entryObject = entry.objectValue,
                      let environmentName = entryObject["name"]?.stringValue,
                      let environmentValue = entryObject["value"]?.stringValue,
                      Self.isValidEnvironmentName(environmentName) else {
                    throw ACPApplicationRuntimeError.invalidConfiguration(
                        "ACP MCP server '\(name)' has an invalid environment entry."
                    )
                }
                guard parsedEnvironment[environmentName] == nil else {
                    throw ACPApplicationRuntimeError.invalidConfiguration(
                        "ACP MCP server '\(name)' has duplicate environment name '\(environmentName)'."
                    )
                }
                parsedEnvironment[environmentName] = environmentValue
            }
            environment = parsedEnvironment
        } else {
            environment = [:]
        }
        let effectiveCwd = object["cwd"]?.stringValue ?? cwd
        guard !effectiveCwd.isEmpty else {
            throw ACPApplicationRuntimeError.invalidConfiguration(
                "ACP MCP server '\(name)' must have a working directory."
            )
        }
        self.name = name
        self.command = command
        self.arguments = arguments.compactMap { $0 }
        self.environment = environment
        self.cwd = effectiveCwd
    }

    private static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.utf8.first,
              first == 0x5F || (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first) else {
            return false
        }
        return name.utf8.dropFirst().allSatisfy { byte in
            byte == 0x5F || (0x30...0x39).contains(byte) ||
                (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }
    }
}

/// Owns all MCP child processes for one ACP session and exposes only the
/// discovered catalog plus validated calls to the model tool boundary.
actor ACPMCPRuntime {
    private struct Connection {
        let configuration: ACPMCPServerConfiguration
        let transport: MCPStdioTransport
        let tools: [MCPToolDescriptor]
        let alias: String
    }

    private var connections: [String: Connection] = [:]
    private var inFlightTransport: MCPStdioTransport?
    private var stopRequested = false

    func start(
        declarations: [MCPJSONValue],
        cwd: String
    ) async throws -> [any Tool] {
        guard !stopRequested else {
            throw MCPStdioTransportError.cancelled
        }
        let names = declarations.compactMap { $0.objectValue?["name"]?.stringValue }
        guard declarations.count == names.count,
              names.count == Set(names).count else {
            throw ACPApplicationRuntimeError.invalidConfiguration(
                "ACP MCP server declarations must have unique names."
            )
        }
        do {
            for declaration in declarations {
                let configuration = try ACPMCPServerConfiguration(
                    value: declaration,
                    cwd: cwd
                )
                let executableURL = try Self.resolveExecutable(configuration.command)
                // ACP env entries are overrides, not a request to remove the
                // helper's normal PATH/HOME. The command itself is resolved
                // before launch, while child MCP processes may still need the
                // inherited environment for their own subprocesses.
                let environment = ProcessInfo.processInfo.environment.merging(
                    configuration.environment
                ) { _, override in override }
                let transport = MCPStdioTransport(
                    executableURL: executableURL,
                    arguments: configuration.arguments,
                    environment: environment,
                    workingDirectoryURL: URL(fileURLWithPath: configuration.cwd)
                )
                // Keep ownership before the first request. Setup failures can
                // happen after initialize but before a connection is visible
                // in the catalog, so the catch must still stop this child.
                inFlightTransport = transport
                try await transport.start(
                    protocolVersion: "2025-06-18",
                    clientName: "TurboCode ACP",
                    clientVersion: "0.1.0"
                )
                let tools = try await Self.listTools(using: transport)
                guard !stopRequested else {
                    throw MCPStdioTransportError.cancelled
                }
                let alias = Self.toolAlias(for: configuration.name)
                guard !connections.values.contains(where: { $0.alias == alias }) else {
                    throw ACPApplicationRuntimeError.invalidConfiguration(
                        "ACP MCP server names collide after tool aliasing."
                    )
                }
                connections[configuration.name] = Connection(
                    configuration: configuration,
                    transport: transport,
                    tools: tools,
                    alias: alias
                )
                inFlightTransport = nil
            }
            return connections.values.sorted { $0.alias < $1.alias }.map {
                ACPMCPTool(
                    name: $0.alias,
                    serverName: $0.configuration.name,
                    serverDescription: "MCP tools from \($0.configuration.name).",
                    tools: $0.tools,
                    runtime: self
                )
            }
        } catch {
            await inFlightTransport?.stop()
            inFlightTransport = nil
            await stop()
            throw error
        }
    }

    func call(
        serverName: String,
        toolName: String,
        arguments: MCPJSONValue
    ) async throws -> MCPToolResult {
        guard let connection = connections[serverName] else {
            throw ACPApplicationRuntimeError.invalidConfiguration(
                "The ACP MCP server '\(serverName)' is not available."
            )
        }
        guard connection.tools.contains(where: { $0.name == toolName }) else {
            throw ACPApplicationRuntimeError.invalidConfiguration(
                "The MCP tool '\(toolName)' is not advertised by '\(serverName)'."
            )
        }
        let response = try await connection.transport.request(
            method: "tools/call",
            params: .object([
                "name": .string(toolName),
                "arguments": arguments
            ])
        )
        guard let object = response.objectValue,
              let content = object["content"]?.arrayValue else {
            throw MCPStdioTransportError.invalidResponse(
                "tools/call result did not contain content."
            )
        }
        return MCPToolResult(
            content: content,
            structuredContent: object["structuredContent"],
            isError: object["isError"]?.boolValue ?? false
        )
    }

    func stop() async {
        stopRequested = true
        let pendingTransport = inFlightTransport
        inFlightTransport = nil
        let transports = connections.values.map(\.transport)
        connections.removeAll()
        if let pendingTransport {
            await pendingTransport.stop()
        }
        for transport in transports {
            await transport.stop()
        }
    }

    private static func listTools(
        using transport: MCPStdioTransport
    ) async throws -> [MCPToolDescriptor] {
        let response = try await transport.request(method: "tools/list")
        guard let rawTools = response.objectValue?["tools"]?.arrayValue else {
            throw MCPStdioTransportError.invalidResponse(
                "tools/list result did not contain a tools array."
            )
        }
        return try rawTools.map { value in
            try JSONDecoder().decode(
                MCPToolDescriptor.self,
                from: JSONEncoder().encode(value)
            )
        }
    }

    private static func resolveExecutable(_ command: String) throws -> URL {
        if command.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: command) {
            return URL(fileURLWithPath: command)
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = "/\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        throw MCPStdioTransportError.executableMissing(command)
    }

    private static func toolAlias(for serverName: String) -> String {
        let sanitized = serverName.map { character in
            character.isLetter || character.isNumber || character == "_"
                ? character
                : "_"
        }
        return "mcp_" + String(sanitized)
    }
}

@Generable
struct ACPMCPToolArguments {
    var operation: String
    var toolName: String?
    var argumentsJSON: String?
}

/// Foundation Models gateway for one ACP-provided MCP server. Nested MCP
/// schemas stay opaque and are validated again before crossing the process
/// boundary.
struct ACPMCPTool: Tool {
    typealias Arguments = ACPMCPToolArguments
    typealias Output = String

    let name: String
    let serverName: String
    let serverDescription: String
    let tools: [MCPToolDescriptor]
    let runtime: ACPMCPRuntime

    var description: String {
        "\(serverDescription) Use list_tools before calling a discovered tool."
    }

    let includesSchemaInInstructions = true

    func call(arguments: ACPMCPToolArguments) async throws -> String {
        switch arguments.operation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "list_tools", "list", "discover":
            return tools.map {
                "- \($0.name): \($0.description ?? "No description provided.")\n  input: \($0.inputSchema?.jsonString ?? "{}")"
            }.joined(separator: "\n")
        case "call":
            let toolName = arguments.toolName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard tools.contains(where: { $0.name == toolName }) else {
                return "Unknown MCP tool '\(toolName)'. Use list_tools first."
            }
            let source = arguments.argumentsJSON?.isEmpty == false
                ? arguments.argumentsJSON!
                : "{}"
            guard let data = source.data(using: .utf8),
                  let value = try? JSONDecoder().decode(MCPJSONValue.self, from: data),
                  value.objectValue != nil else {
                return "MCP argumentsJSON must be a valid JSON object."
            }
            let result = try await runtime.call(
                serverName: serverName,
                toolName: toolName,
                arguments: value
            )
            return result.renderedForModel
        default:
            return "Unknown MCP operation. Use list_tools or call."
        }
    }
}
