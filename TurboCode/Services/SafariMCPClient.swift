import Foundation

// MARK: - MCP wire values

/// Small JSON value type used by the Safari bridge so the MCP transport does
/// not depend on the Codex App Server representation.
nonisolated enum SafariMCPJSONValue: Codable, Hashable, Sendable {
    case object([String: SafariMCPJSONValue])
    case array([SafariMCPJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: SafariMCPJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([SafariMCPJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: SafariMCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [SafariMCPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> SafariMCPJSONValue? {
        objectValue?[key]
    }

    func compactJSONString(maxCharacters: Int = 1_200) -> String {
        let rendered: String
        if let data = try? JSONEncoder().encode(self),
           let string = String(data: data, encoding: .utf8) {
            rendered = string
        } else {
            rendered = "{}"
        }
        guard rendered.count > maxCharacters else { return rendered }
        return String(rendered.prefix(maxCharacters)) + "…"
    }
}

nonisolated struct SafariMCPToolDescriptor: Codable, Hashable, Sendable {
    let name: String
    let description: String?
    let inputSchema: SafariMCPJSONValue?

    init(
        name: String,
        description: String? = nil,
        inputSchema: SafariMCPJSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

nonisolated enum SafariMCPError: LocalizedError, Sendable, Equatable {
    case executableMissing
    case processUnavailable
    case processStopped(String)
    case requestTimedOut(String)
    case invalidResponse(String)
    case toolFailed(String)
    case unsupportedTool(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            "safaridriver is not available at /usr/bin/safaridriver."
        case .processUnavailable:
            "The safaridriver MCP process is not running."
        case .processStopped(let detail):
            detail
        case .requestTimedOut(let method):
            "Safari MCP request '\(method)' timed out."
        case .invalidResponse(let detail):
            "Safari MCP returned an invalid response: \(detail)"
        case .toolFailed(let detail):
            detail
        case .unsupportedTool(let name):
            "Safari MCP did not advertise the '\(name)' tool."
        }
    }
}

// MARK: - JSON-RPC transport

/// Lazy, actor-isolated JSON-RPC client for Apple's `safaridriver --mcp`.
/// Keeping the child process behind this boundary prevents browser transport
/// state from entering the main actor or the model session itself.
actor SafariMCPClient {
    static let shared = SafariMCPClient()

    private static let executableURL = URL(fileURLWithPath: "/usr/bin/safaridriver")
    private static let handshakeTimeout: Duration = .seconds(20)
    private static let callTimeout: Duration = .seconds(180)

    private var process: Process?
    private var inputHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var startupTask: Task<Void, Error>?
    private var outputBuffer = Data()
    private var pending: [Int: CheckedContinuation<SafariMCPJSONValue, any Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var nextRequestID = 1
    private var initialized = false
    private(set) var tools: [SafariMCPToolDescriptor] = []
    private(set) var lastError: String?

    func listTools() async throws -> [SafariMCPToolDescriptor] {
        try await ensureStarted()
        return tools
    }

    func call(
        tool name: String,
        arguments: SafariMCPJSONValue
    ) async throws -> String {
        var contextRecoveryAttempted = false
        for attempt in 0..<2 {
            do {
                try await ensureStarted()
                guard tools.contains(where: { $0.name == name }) else {
                    throw SafariMCPError.unsupportedTool(name)
                }
                let result = try await request(
                    method: "tools/call",
                    params: .object([
                        "name": .string(name),
                        "arguments": arguments
                    ]),
                    timeout: Self.callTimeout
                )
                let isError = result["isError"]?.boolValue == true
                let text = Self.text(from: result)
                if isError {
                    // Safari can keep the MCP process alive while dropping its
                    // selected browsing context between user turns. Reattach
                    // to the active tab once before surfacing the tool error.
                    if !contextRecoveryAttempted,
                       Self.isMissingBrowsingContext(text) {
                        contextRecoveryAttempted = true
                        if await recoverBrowsingContext() {
                            continue
                        }
                    }
                    throw SafariMCPError.toolFailed(text)
                }
                return text
            } catch let error as SafariMCPError {
                guard attempt == 0, case .processStopped = error else { throw error }
                stop()
            } catch {
                if attempt == 0 {
                    stop()
                    continue
                }
                throw error
            }
        }
        throw SafariMCPError.processUnavailable
    }

    /// Re-establishes Safari's current tab after the server loses its
    /// browsing context. This deliberately uses one retry and never starts a
    /// second MCP process, preserving the existing Safari session.
    private func recoverBrowsingContext() async -> Bool {
        guard tools.contains(where: { $0.name == "list_tabs" }),
              tools.contains(where: { $0.name == "switch_tab" }) else {
            return false
        }

        do {
            let list = try await request(
                method: "tools/call",
                params: .object([
                    "name": .string("list_tabs"),
                    "arguments": .object([:])
                ]),
                timeout: Self.handshakeTimeout
            )
            guard list["isError"]?.boolValue != true,
                  let handle = Self.preferredTabHandle(from: list) else {
                return false
            }

            let switched = try await request(
                method: "tools/call",
                params: .object([
                    "name": .string("switch_tab"),
                    "arguments": .object(["handle": .string(handle)])
                ]),
                timeout: Self.handshakeTimeout
            )
            return switched["isError"]?.boolValue != true
        } catch {
            return false
        }
    }

    func stop() {
        let currentProcess = process
        process = nil
        inputHandle = nil
        initialized = false
        tools = []
        readerTask?.cancel()
        errorReaderTask?.cancel()
        readerTask = nil
        errorReaderTask = nil
        if currentProcess?.isRunning == true {
            currentProcess?.terminate()
        }
        let error = SafariMCPError.processStopped("The safaridriver MCP process stopped.")
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
    }

    private func ensureStarted() async throws {
        if initialized, process?.isRunning == true { return }
        if let startupTask {
            try await startupTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { throw SafariMCPError.processUnavailable }
            try await self.launchAndInitialize()
        }
        startupTask = task
        do {
            try await task.value
            startupTask = nil
        } catch {
            startupTask = nil
            throw error
        }
    }

    private func launchAndInitialize() async throws {
        stop()
        guard FileManager.default.isExecutableFile(atPath: Self.executableURL.path) else {
            throw SafariMCPError.executableMissing
        }

        let child = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        child.executableURL = Self.executableURL
        child.arguments = ["--mcp"]
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = errorPipe
        do {
            try child.run()
        } catch {
            throw SafariMCPError.processStopped(error.localizedDescription)
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
                    "protocolVersion": .string("2024-11-05"),
                    "capabilities": .object([:]),
                    "clientInfo": .object([
                        "name": .string("turbocode"),
                        "version": .string("0.1")
                    ])
                ]),
                timeout: Self.handshakeTimeout
            )
            try sendNotification(method: "notifications/initialized")
            let list = try await request(
                method: "tools/list",
                params: .object([:]),
                timeout: Self.handshakeTimeout
            )
            tools = Self.parseTools(from: list)
            initialized = true
        } catch {
            stop()
            throw error
        }
    }

    private func request(
        method: String,
        params: SafariMCPJSONValue,
        timeout: Duration
    ) async throws -> SafariMCPJSONValue {
        guard process?.isRunning == true, inputHandle != nil else {
            throw SafariMCPError.processUnavailable
        }
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.timeout(id: id, method: method)
            }
            do {
                try send(
                    .object([
                        "jsonrpc": .string("2.0"),
                        "id": .number(Double(id)),
                        "method": .string(method),
                        "params": params
                    ])
                )
            } catch {
                timeoutTasks[id]?.cancel()
                timeoutTasks.removeValue(forKey: id)
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String) throws {
        try send(.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method)
        ]))
    }

    private func send(_ value: SafariMCPJSONValue) throws {
        guard let inputHandle else { throw SafariMCPError.processUnavailable }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let message = try? JSONDecoder().decode(
                    SafariMCPJSONValue.self,
                    from: line
                  ) else { continue }
            handle(message)
        }
    }

    private func receiveError(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { lastError = text }
    }

    private func handle(_ message: SafariMCPJSONValue) {
        guard let object = message.objectValue,
              let idValue = object["id"],
              case .number(let rawID) = idValue else { return }
        let id = Int(rawID)
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if let error = object["error"]?.objectValue,
           let detail = error["message"]?.stringValue {
            continuation.resume(throwing: SafariMCPError.toolFailed(detail))
        } else {
            continuation.resume(returning: object["result"] ?? .null)
        }
    }

    private func timeout(id: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)
        continuation.resume(throwing: SafariMCPError.requestTimedOut(method))
    }

    private func serverDidStop() {
        guard process != nil else { return }
        let error = SafariMCPError.processStopped(
            lastError ?? "The safaridriver MCP process stopped unexpectedly."
        )
        process = nil
        inputHandle = nil
        initialized = false
        tools = []
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
    }

    private static func parseTools(from value: SafariMCPJSONValue) -> [SafariMCPToolDescriptor] {
        guard let rawTools = value["tools"]?.arrayValue else { return [] }
        return rawTools.compactMap { raw in
            guard let object = raw.objectValue,
                  let name = object["name"]?.stringValue,
                  !name.isEmpty else { return nil }
            return SafariMCPToolDescriptor(
                name: name,
                description: object["description"]?.stringValue,
                inputSchema: object["inputSchema"]
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func isMissingBrowsingContext(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("could not find browsing context")
    }

    /// Extracts the active tab handle from the JSON returned by `list_tabs`.
    /// The MCP server currently returns JSON in a text content block, while
    /// accepting structured content here keeps the bridge tolerant of either
    /// representation.
    nonisolated static func preferredTabHandle(from result: SafariMCPJSONValue) -> String? {
        var payloads: [SafariMCPJSONValue] = []
        if let structured = result["structuredContent"] {
            payloads.append(structured)
        }
        if let content = result["content"]?.arrayValue {
            for item in content {
                guard let text = item["text"]?.stringValue,
                      let data = text.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(
                          SafariMCPJSONValue.self,
                          from: data
                      ) else { continue }
                payloads.append(payload)
            }
        }
        if result["tabs"] != nil || result.arrayValue != nil {
            payloads.append(result)
        }

        for payload in payloads {
            let tabs = payload["tabs"]?.arrayValue ?? payload.arrayValue ?? []
            let descriptors = tabs.compactMap { tab -> (String, Bool)? in
                guard let object = tab.objectValue,
                      let handle = object["handle"]?.stringValue,
                      !handle.isEmpty else { return nil }
                return (handle, object["active"]?.boolValue == true)
            }
            if let active = descriptors.first(where: { $0.1 }) {
                return active.0
            }
            if let first = descriptors.first {
                return first.0
            }
        }
        return nil
    }

    private static func text(from value: SafariMCPJSONValue) -> String {
        if let texts = value["content"]?.arrayValue?.compactMap({ item in
            item["text"]?.stringValue
        }), !texts.isEmpty {
            return texts.joined(separator: "\n")
        }
        if let structured = value["structuredContent"] {
            return structured.compactJSONString(maxCharacters: 20_000)
        }
        return value.compactJSONString(maxCharacters: 20_000)
    }
}
