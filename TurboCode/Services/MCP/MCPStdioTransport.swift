import Foundation

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
    private let startupTimeout: Duration
    private let requestTimeout: Duration

    private var process: Process?
    private var inputHandle: FileHandle?
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
        startupTimeout: Duration = .seconds(20),
        requestTimeout: Duration = .seconds(180)
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.startupTimeout = startupTimeout
        self.requestTimeout = requestTimeout
    }

    func start(
        protocolVersion: String,
        clientName: String,
        clientVersion: String
    ) async throws {
        guard process?.isRunning != true else { return }
        stop()
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
            stop()
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

    func stop() {
        let currentProcess = process
        process = nil
        inputHandle = nil
        readerTask?.cancel()
        errorReaderTask?.cancel()
        readerTask = nil
        errorReaderTask = nil
        if currentProcess?.isRunning == true {
            currentProcess?.terminate()
        }
        let error = MCPStdioTransportError.processStopped(
            lastError ?? "The MCP process stopped."
        )
        failPending(with: error)
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
        inputHandle = nil
        failPending(with: error)
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
