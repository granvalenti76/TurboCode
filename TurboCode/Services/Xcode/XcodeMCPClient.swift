import Foundation

/// MCP client for the Xcode-provided `xcrun mcpbridge` service. The client is
/// lazy and keeps one connection across model turns; a later turn may create a
/// fresh connection after Xcode or the bridge restarts.
actor XcodeMCPClient {
    static let shared = XcodeMCPClient()

    private static let protocolVersion = "2024-11-05"
    private let transport: MCPStdioTransport
    private var initialized = false
    private(set) var tools: [MCPToolDescriptor] = []

    init(transport: MCPStdioTransport = MCPStdioTransport()) {
        self.transport = transport
    }

    func listTools() async throws -> [MCPToolDescriptor] {
        try await ensureStarted()
        return tools
    }

    func call(tool name: String, arguments: MCPJSONValue) async throws -> MCPToolResult {
        try await ensureStarted()
        guard tools.contains(where: { $0.name == name }) else {
            throw MCPStdioTransportError.invalidResponse(
                "Xcode MCP did not advertise the '\(name)' tool."
            )
        }
        let value = try await transport.request(
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": arguments
            ])
        )
        guard let object = value.objectValue else {
            throw MCPStdioTransportError.invalidResponse(
                "Xcode MCP returned a non-object tool result."
            )
        }
        return MCPToolResult(
            content: object["content"]?.arrayValue ?? [],
            structuredContent: object["structuredContent"],
            isError: object["isError"]?.boolValue == true
        )
    }

    /// Stops only the bridge process. The caller must not interpret this as
    /// confirmation that Xcode stopped an already-running build or mutation.
    func stop() async {
        initialized = false
        tools = []
        await transport.stop()
    }

    private func ensureStarted() async throws {
        if initialized, await transport.isRunning() {
            return
        }
        initialized = false
        tools = []
        try await transport.start(
            protocolVersion: Self.protocolVersion,
            clientName: "turbocode",
            clientVersion: "0.1"
        )
        do {
            tools = try await discoverTools()
            initialized = true
        } catch {
            await stop()
            throw error
        }
    }

    private func discoverTools() async throws -> [MCPToolDescriptor] {
        var cursor: String?
        var result: [MCPToolDescriptor] = []
        var seenCursors: Set<String> = []
        for _ in 0..<100 {
            var params: [String: MCPJSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let page = try await transport.request(
                method: "tools/list",
                params: .object(params)
            )
            guard let object = page.objectValue else {
                throw MCPStdioTransportError.invalidResponse(
                    "Xcode MCP returned a non-object tools/list result."
                )
            }
            if let pageTools = object["tools"]?.arrayValue {
                result.append(contentsOf: pageTools.compactMap(Self.parseTool))
            }
            guard let next = object["nextCursor"]?.stringValue,
                  !next.isEmpty else {
                return Self.uniqueAndSorted(result)
            }
            guard seenCursors.insert(next).inserted else {
                throw MCPStdioTransportError.invalidResponse(
                    "Xcode MCP repeated a tools/list cursor."
                )
            }
            cursor = next
        }
        throw MCPStdioTransportError.invalidResponse(
            "Xcode MCP exceeded the tools/list pagination limit."
        )
    }

    private static func parseTool(_ value: MCPJSONValue) -> MCPToolDescriptor? {
        guard let object = value.objectValue,
              let name = object["name"]?.stringValue,
              !name.isEmpty else { return nil }
        return MCPToolDescriptor(
            name: name,
            description: object["description"]?.stringValue,
            inputSchema: object["inputSchema"]
        )
    }

    private static func uniqueAndSorted(
        _ tools: [MCPToolDescriptor]
    ) -> [MCPToolDescriptor] {
        var byName: [String: MCPToolDescriptor] = [:]
        for tool in tools {
            byName[tool.name] = tool
        }
        return byName.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
