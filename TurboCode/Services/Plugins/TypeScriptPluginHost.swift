import Foundation

nonisolated struct TypeScriptPluginHandshake: Sendable, Equatable {
    let protocolVersion: Int
    let pluginID: String
    let nodeVersion: String
    let tools: [String]
}

nonisolated struct TypeScriptPluginHostConfiguration: Sendable {
    let manifest: TypeScriptPluginManifest
    let pluginRoot: URL
    let nodePolicy: NodeRuntimePolicy
    let requestTimeout: Duration
    /// Supplies a point-in-time copy of the active session. The provider is
    /// owned by app composition, so the host does not retain ChatStore or any
    /// Swift object inside the Node process.
    let sessionTranscript: @Sendable () async -> PluginJSONValue?

    init(
        manifest: TypeScriptPluginManifest,
        pluginRoot: URL,
        nodePolicy: NodeRuntimePolicy = .init(),
        requestTimeout: Duration = .seconds(10),
        sessionTranscript: @escaping @Sendable () async -> PluginJSONValue? = { nil }
    ) {
        self.manifest = manifest
        self.pluginRoot = pluginRoot
        self.nodePolicy = nodePolicy
        self.requestTimeout = requestTimeout
        self.sessionTranscript = sessionTranscript
    }
}

nonisolated enum TypeScriptPluginHostError: LocalizedError, Sendable, Equatable {
    case alreadyRunning
    case notRunning
    case handshakeFailed(String)
    case processStopped
    case invalidResponse(String)
    case rpc(code: Int, message: String)
    case requestTimedOut(String)
    case outputLimitExceeded

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "The TypeScript plugin is already running."
        case .notRunning: "The TypeScript plugin is not running."
        case .handshakeFailed(let detail): "TypeScript plugin handshake failed: \(detail)"
        case .processStopped: "The TypeScript plugin stopped unexpectedly."
        case .invalidResponse(let detail): "Invalid TypeScript plugin response: \(detail)"
        case .rpc(_, let message): "TypeScript plugin error: \(message)"
        case .requestTimedOut(let method): "TypeScript plugin timed out: \(method)."
        case .outputLimitExceeded: "TypeScript plugin response exceeded the host limit."
        }
    }
}

/// Owns one lazy Node process and its JSON-RPC 2.0 JSONL transport. No actor
/// instance is created by TurboCode until a validated plugin is activated.
actor TypeScriptPluginHost {
    private static let maximumMessageBytes = 1_000_000

    private let configuration: TypeScriptPluginHostConfiguration
    private var process: Process?
    private var inputHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var lastStandardErrorLine: String?
    private var pending: [Int: CheckedContinuation<PluginJSONValue, any Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var nextRequestID = 1
    private var started = false

    init(configuration: TypeScriptPluginHostConfiguration) {
        self.configuration = configuration
    }

    func start() async throws -> TypeScriptPluginHandshake {
        guard !started else { throw TypeScriptPluginHostError.alreadyRunning }
        try configuration.manifest.validate(at: configuration.pluginRoot)
        let node = try NodeRuntimeResolver.resolve(policy: configuration.nodePolicy)
        let entrypoint = configuration.pluginRoot
            .appendingPathComponent(configuration.manifest.entrypoint)

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = node
        process.arguments = [
            "--unhandled-rejections=strict",
            entrypoint.path
        ]
        process.currentDirectoryURL = configuration.pluginRoot
        var environment = ProcessInfo.processInfo.environment
        environment["TURBOCODE_PLUGIN_ID"] = configuration.manifest.id
        environment["TURBOCODE_PLUGIN_PROTOCOL"] = String(TypeScriptPluginManifest.supportedProtocolVersion)
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        started = true

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        readerTask = Task.detached { [weak self, outputHandle] in
            while !Task.isCancelled {
                let data = outputHandle.availableData
                guard !data.isEmpty else {
                    await self?.processDidStop()
                    return
                }
                await self?.receive(data)
            }
        }
        errorReaderTask = Task.detached { [weak self, errorHandle] in
            while !Task.isCancelled {
                let data = errorHandle.availableData
                guard !data.isEmpty else { return }
                await self?.receiveStandardError(data)
            }
        }

        do {
            let value = try await request(
                method: "initialize",
                params: .object([
                    "protocolVersion": .integer(TypeScriptPluginManifest.supportedProtocolVersion),
                    "pluginID": .string(configuration.manifest.id)
                ])
            )
            let handshake = try decodeHandshake(value)
            guard handshake.protocolVersion == TypeScriptPluginManifest.supportedProtocolVersion,
                  handshake.pluginID == configuration.manifest.id,
                  handshake.tools == configuration.manifest.tools.map(\.name),
                  Self.nodeMajor(handshake.nodeVersion) == configuration.nodePolicy.supportedMajor else {
                throw TypeScriptPluginHostError.handshakeFailed("manifest, protocol, tool list, or Node version mismatch")
            }
            return handshake
        } catch {
            shutdown()
            throw error
        }
    }

    func call(tool: String, arguments: PluginJSONValue) async throws -> String {
        guard started else { throw TypeScriptPluginHostError.notRunning }
        let value = try await request(
            method: "tools/call",
            params: .object([
                "name": .string(tool),
                "arguments": arguments
            ])
        )
        guard let text = value["text"]?.stringValue else {
            throw TypeScriptPluginHostError.invalidResponse("tools/call did not return text")
        }
        return text
    }

    func isRunning() -> Bool {
        process?.isRunning == true && started
    }

    func shutdown() {
        readerTask?.cancel()
        readerTask = nil
        errorReaderTask?.cancel()
        errorReaderTask = nil
        for continuation in pending.values {
            continuation.resume(throwing: TypeScriptPluginHostError.processStopped)
        }
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        try? inputHandle?.close()
        inputHandle = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        started = false
    }

    private func request(
        method: String,
        params: PluginJSONValue
    ) async throws -> PluginJSONValue {
        guard inputHandle != nil else { throw TypeScriptPluginHostError.notRunning }
        let id = nextRequestID
        nextRequestID += 1
        let timeout = configuration.requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeoutTasks[id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self?.requestTimedOut(id: id, method: method)
            }
            do {
                try send(.object([
                    "jsonrpc": .string("2.0"),
                    "id": .integer(id),
                    "method": .string(method),
                    "params": params
                ]))
            } catch {
                timeoutTasks.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    private func send(_ value: PluginJSONValue) throws {
        guard let inputHandle else { throw TypeScriptPluginHostError.notRunning }
        var data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumMessageBytes else {
            throw TypeScriptPluginHostError.outputLimitExceeded
        }
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        guard outputBuffer.count <= Self.maximumMessageBytes else {
            failPending(TypeScriptPluginHostError.outputLimitExceeded)
            return
        }
        for line in Self.framedLines(from: &outputBuffer) {
            guard !line.isEmpty else { continue }
            do {
                let message = try JSONDecoder().decode(
                    PluginRPCMessage.self,
                    from: Data(line.utf8)
                )
                if let method = message.method {
                    guard let id = message.id else { continue }
                    Task { [weak self] in
                        await self?.handlePluginRequest(
                            id: id,
                            method: method,
                            params: message.params
                        )
                    }
                    continue
                }
                guard case .integer(let id)? = message.id else { continue }
                timeoutTasks.removeValue(forKey: id)?.cancel()
                guard let continuation = pending.removeValue(forKey: id) else { continue }
                if let error = message.error {
                    continuation.resume(throwing: TypeScriptPluginHostError.rpc(code: error.code, message: error.message))
                } else if let result = message.result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: TypeScriptPluginHostError.invalidResponse("missing result"))
                }
            } catch {
                failPending(TypeScriptPluginHostError.invalidResponse("malformed JSON-RPC message"))
            }
        }
    }

    /// Frames arbitrary pipe chunks without exposing incomplete JSON records.
    nonisolated static func framedLines(from buffer: inout Data) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty, let string = String(data: line, encoding: .utf8) {
                lines.append(string)
            }
        }
        return lines
    }

    private func receiveStandardError(_ data: Data) {
        errorBuffer.append(data)
        for line in Self.framedLines(from: &errorBuffer) {
            lastStandardErrorLine = String(line.suffix(500))
        }
    }

    /// Handles requests initiated by the plugin while a normal tool call is
    /// still pending. Keeping this bidirectional avoids exposing a file path
    /// or a Swift object and lets the SDK provide a typed session API.
    private func handlePluginRequest(
        id: PluginRPCID,
        method: String,
        params: PluginJSONValue?
    ) async {
        do {
            guard method == "session/readTranscript" else {
                try sendError(
                    id: id,
                    code: -32601,
                    message: "Unsupported plugin request: \(method)."
                )
                return
            }
            _ = params
            try sendResponse(
                id: id,
                result: await configuration.sessionTranscript() ?? .null
            )
        } catch {
            try? sendError(
                id: id,
                code: -32000,
                message: error.localizedDescription
            )
        }
    }

    private func sendResponse(id: PluginRPCID, result: PluginJSONValue) throws {
        try send(.object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "result": result
        ]))
    }

    private func sendError(id: PluginRPCID, code: Int, message: String) throws {
        try send(.object([
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
            "error": .object([
                "code": .integer(code),
                "message": .string(message)
            ])
        ]))
    }

    private func processDidStop() {
        guard started else { return }
        failPending(TypeScriptPluginHostError.processStopped)
        started = false
    }

    private func requestTimedOut(id: Int, method: String) {
        timeoutTasks.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(
            throwing: TypeScriptPluginHostError.requestTimedOut(method)
        )
    }

    private func failPending(_ error: any Error) {
        let continuations = pending.values
        pending.removeAll()
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private func decodeHandshake(_ value: PluginJSONValue) throws -> TypeScriptPluginHandshake {
        let data = try JSONEncoder().encode(value)
        do {
            return try JSONDecoder().decode(TypeScriptPluginHandshakePayload.self, from: data).handshake
        } catch {
            throw TypeScriptPluginHostError.handshakeFailed("invalid handshake payload")
        }
    }

    private static func nodeMajor(_ version: String) -> Int? {
        Int(version.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").first ?? "")
    }
}

private nonisolated struct PluginRPCError: Codable, Sendable {
    let code: Int
    let message: String
}

private nonisolated enum PluginRPCID: Codable, Sendable, Equatable {
    case integer(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) {
            self = .integer(integer)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    var jsonValue: PluginJSONValue {
        switch self {
        case .integer(let value): .integer(value)
        case .string(let value): .string(value)
        }
    }
}

private nonisolated struct PluginRPCMessage: Codable, Sendable {
    let id: PluginRPCID?
    let method: String?
    let params: PluginJSONValue?
    let result: PluginJSONValue?
    let error: PluginRPCError?
}

private nonisolated struct TypeScriptPluginHandshakePayload: Codable, Sendable {
    let protocolVersion: Int
    let pluginID: String
    let nodeVersion: String
    let tools: [String]

    var handshake: TypeScriptPluginHandshake {
        TypeScriptPluginHandshake(
            protocolVersion: protocolVersion,
            pluginID: pluginID,
            nodeVersion: nodeVersion,
            tools: tools
        )
    }
}
