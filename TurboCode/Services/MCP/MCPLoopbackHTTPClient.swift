import Foundation

nonisolated enum MCPLoopbackHTTPError: LocalizedError, Equatable, Sendable {
    /// Nothing listens on the endpoint: the app is closed or its server is off.
    case notRunning
    case http(status: Int)
    case invalidResponse(String)
    case rpc(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "The app is not running or its MCP server is turned off."
        case .http(let status): "The MCP server answered HTTP \(status)."
        case .invalidResponse(let detail): "The MCP server returned an invalid response: \(detail)"
        case .rpc(let code, let message): "MCP JSON-RPC error \(code): \(message)"
        }
    }
}

/// MCP over streamable HTTP for a connector served on the loopback interface.
///
/// One actor per endpoint keeps the optional MCP session identifier and the
/// request counter off the main actor. The client sends no `Origin` header,
/// no cookies, and uses no proxy: a local MCP server commonly rejects browser
/// origins, and a system proxy must never see a request meant for this Mac.
actor MCPLoopbackHTTPClient {
    private static let protocolVersion = "2025-06-18"
    private static let handshakeTimeout: TimeInterval = 5
    /// Sculpting operations such as a remesh of a dense mesh take a while.
    private static let callTimeout: TimeInterval = 180

    private let endpoint: MCPLoopbackEndpoint
    private let session: URLSession
    private var sessionID: String?
    private var initialized = false
    private var nextRequestID = 1

    init(endpoint: MCPLoopbackEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration)
    }

    func listTools() async throws -> [MCPToolDescriptor] {
        let result = try await initializedRequest(method: "tools/list", params: nil, timeout: Self.handshakeTimeout)
        return Self.parseTools(result)
    }

    func call(tool name: String, arguments: MCPJSONValue) async throws -> MCPToolResult {
        let result = try await initializedRequest(
            method: "tools/call",
            params: .object(["name": .string(name), "arguments": arguments]),
            timeout: Self.callTimeout
        )
        return MCPToolResult(
            content: result.objectValue?["content"]?.arrayValue ?? [],
            structuredContent: result.objectValue?["structuredContent"],
            isError: result.objectValue?["isError"]?.boolValue == true
        )
    }

    // MARK: Requests

    /// Runs one request after the MCP handshake. The app can be restarted
    /// while a session stays open, which invalidates the handshake: a failed
    /// request is retried once from a fresh handshake, but never a tool call,
    /// because a call that may already have changed the scene must not repeat.
    private func initializedRequest(
        method: String,
        params: MCPJSONValue?,
        timeout: TimeInterval
    ) async throws -> MCPJSONValue {
        do {
            try await initializeIfNeeded()
            return try await request(method: method, params: params, timeout: timeout)
        } catch {
            initialized = false
            sessionID = nil
            guard method != "tools/call" else { throw error }
            try await initializeIfNeeded()
            return try await request(method: method, params: params, timeout: timeout)
        }
    }

    private func initializeIfNeeded() async throws {
        guard !initialized else { return }
        _ = try await request(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("TurboCode"), "version": .string("1")])
            ]),
            timeout: Self.handshakeTimeout
        )
        try await send(
            .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]),
            timeout: Self.handshakeTimeout
        )
        initialized = true
    }

    private func request(method: String, params: MCPJSONValue?, timeout: TimeInterval) async throws -> MCPJSONValue {
        let id = nextRequestID
        nextRequestID += 1
        var message: [String: MCPJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method)
        ]
        if let params { message["params"] = params }
        let (data, contentType) = try await send(.object(message), timeout: timeout)
        return try Self.result(forID: id, in: data, contentType: contentType)
    }

    @discardableResult
    private func send(_ message: MCPJSONValue, timeout: TimeInterval) async throws -> (Data, String?) {
        var request = URLRequest(url: endpoint.url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(message)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where Self.meansNotRunning(error.code) {
            throw MCPLoopbackHTTPError.notRunning
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPLoopbackHTTPError.invalidResponse("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPLoopbackHTTPError.http(status: http.statusCode)
        }
        // A stateful server names its session in the handshake response and
        // expects the identifier back; a stateless one sends none.
        if let assigned = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = assigned }
        return (data, http.value(forHTTPHeaderField: "Content-Type"))
    }

    private static func meansNotRunning(_ code: URLError.Code) -> Bool {
        code == .cannotConnectToHost || code == .networkConnectionLost || code == .cannotFindHost
    }

    // MARK: Parsing

    /// Extracts the JSON-RPC result for `id` from a response body.
    ///
    /// Streamable HTTP lets the server answer with one JSON object or with a
    /// short event stream whose `data:` lines carry JSON-RPC messages; the
    /// stream may hold notifications before the response.
    nonisolated static func result(forID id: Int, in data: Data, contentType: String?) throws -> MCPJSONValue {
        let payloads: [Data]
        if contentType?.lowercased().contains("text/event-stream") == true {
            payloads = String(decoding: data, as: UTF8.self)
                .components(separatedBy: .newlines)
                .filter { $0.hasPrefix("data:") }
                .map { Data($0.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8) }
        } else {
            payloads = [data]
        }
        for payload in payloads {
            guard let message = try? JSONDecoder().decode(MCPJSONValue.self, from: payload).objectValue,
                  message["id"] == .number(Double(id)) else { continue }
            if let error = message["error"]?.objectValue {
                var code = 0
                if case .number(let value)? = error["code"] { code = Int(value) }
                throw MCPLoopbackHTTPError.rpc(code: code, message: error["message"]?.stringValue ?? "Unknown error")
            }
            guard let result = message["result"] else { break }
            return result
        }
        throw MCPLoopbackHTTPError.invalidResponse("no result for request \(id)")
    }

    nonisolated static func parseTools(_ result: MCPJSONValue) -> [MCPToolDescriptor] {
        (result.objectValue?["tools"]?.arrayValue ?? []).compactMap { value in
            guard let tool = value.objectValue, let name = tool["name"]?.stringValue else { return nil }
            return MCPToolDescriptor(
                name: name,
                description: tool["description"]?.stringValue,
                inputSchema: tool["inputSchema"]
            )
        }
    }
}

/// Hands out one client per connector, so every session and the Connectors
/// page talk to an app through the same handshake.
actor MCPConnectorClients {
    static let shared = MCPConnectorClients()

    private var clients: [String: MCPLoopbackHTTPClient] = [:]

    func client(for connector: MCPConnector) -> MCPLoopbackHTTPClient {
        if let client = clients[connector.id] { return client }
        let client = MCPLoopbackHTTPClient(endpoint: connector.endpoint)
        clients[connector.id] = client
        return client
    }
}
