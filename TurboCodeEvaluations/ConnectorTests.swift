import Foundation
import Testing
@testable import TurboCode

/// Connectors let a session drive another app, so these tests pin the three
/// boundaries that keep them safe: only the loopback interface is reachable,
/// a session gets a connector only when its user enabled it, and a result
/// never floods the conversation with image bytes.
@Suite("Connectors")
struct ConnectorTests {
    // MARK: Endpoint and catalog

    @Test("An endpoint can only name an unprivileged port on the loopback interface")
    func endpointIsLoopbackOnly() throws {
        let endpoint = try #require(MCPLoopbackEndpoint(port: 48_765, path: "/mcp"))
        #expect(endpoint.url.absoluteString == "http://127.0.0.1:48765/mcp")
        #expect(MCPLoopbackEndpoint(port: 80, path: "/mcp") == nil)
        #expect(MCPLoopbackEndpoint(port: 70_000, path: "/mcp") == nil)
        #expect(MCPLoopbackEndpoint(port: 48_765, path: "mcp") == nil)
        #expect(MCPLoopbackEndpoint(port: 48_765, path: "/../x") == nil)
        #expect(MCPLoopbackEndpoint(port: 48_765, path: "/mcp?to=elsewhere") == nil)
        for connector in MCPConnectorCatalog.all {
            #expect(connector.endpoint.url.host() == "127.0.0.1")
        }
    }

    @Test("A session receives only known connectors it enabled, within its domain")
    func enabledConnectorsFollowSelectionAndDomain() {
        #expect(MCPConnectorCatalog.enabled(ids: [], domain: .cowork).isEmpty)
        #expect(MCPConnectorCatalog.enabled(ids: ["removed-connector"], domain: .coding).isEmpty)
        #expect(MCPConnectorCatalog.enabled(ids: ["prassitele"], domain: .cowork).map(\.id) == ["prassitele"])
        #expect(Set(MCPConnectorCatalog.all.map(\.id)).count == MCPConnectorCatalog.all.count)
    }

    @Test("Flipping a connector keeps the stored list stable and free of duplicates")
    func selectionIsStable() {
        let on = MCPConnectorCatalog.ids([], setting: "prassitele", enabled: true)
        #expect(on == ["prassitele"])
        #expect(MCPConnectorCatalog.ids(on, setting: "prassitele", enabled: true) == on)
        #expect(MCPConnectorCatalog.ids(on, setting: "prassitele", enabled: false).isEmpty)
    }

    // MARK: Tool plans

    private static func context(connectors: Bool) -> ToolAccessContext {
        ToolAccessContext(
            hasWorkspace: true,
            hasSkills: true,
            safariMCPEnabled: true,
            xcodeMCPEnabled: true,
            hasSessionConnectors: connectors,
            hasDelegateModel: true,
            repositoryMapDetail: nil
        )
    }

    @Test("A Coding session registers the gateway only while a connector is enabled")
    func codingPlanFollowsTheSession() {
        for selection in [nil, Set<ToolCapabilityID>([.readFile]), Set(ToolCapabilityID.allCases)] {
            let off = ModelToolCatalog.plan(
                profile: .standalone, tier: .standard, context: Self.context(connectors: false), selectedIDs: selection
            )
            let on = ModelToolCatalog.plan(
                profile: .standalone, tier: .standard, context: Self.context(connectors: true), selectedIDs: selection
            )
            #expect(!off.registeredIDs.contains(.connector))
            #expect(on.registeredIDs.contains(.connector))
        }
    }

    @Test("Delegated workers never receive the gateway")
    func delegatesNeverGetConnectors() {
        for selection in [nil, Set(ToolCapabilityID.allCases)] {
            let plan = ModelToolCatalog.plan(
                profile: .delegate, tier: .enhanced, context: Self.context(connectors: true), selectedIDs: selection
            )
            #expect(!plan.registeredIDs.contains(.connector))
        }
    }

    @Test("A Studio session with a connector gains the gateway and no other host capability")
    func studioPlanAddsOnlyTheGateway() {
        let without = ModelToolCatalog.coworkPlan(tier: .standard, context: Self.context(connectors: false))
        let with = ModelToolCatalog.coworkPlan(tier: .standard, context: Self.context(connectors: true))

        #expect(!without.registeredIDs.contains(.connector))
        #expect(Set(with.registeredIDs).subtracting(without.registeredIDs) == [.connector])
        #expect(Set(with.registeredIDs).isDisjoint(with: CoworkSessionToolsTests.hostCapabilities.subtracting([.connector])))
    }

    // MARK: Protocol

    @Test("A result is read from a JSON body and from an event stream")
    func resultIsReadFromBothResponseForms() throws {
        let json = Data(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#.utf8)
        #expect(try MCPLoopbackHTTPClient.result(forID: 7, in: json, contentType: "application/json")
            == .object(["ok": .bool(true)]))

        let stream = Data("""
            event: message
            data: {"jsonrpc":"2.0","method":"notifications/progress"}

            event: message
            data: {"jsonrpc":"2.0","id":7,"result":{"ok":true}}

            """.utf8)
        #expect(try MCPLoopbackHTTPClient.result(forID: 7, in: stream, contentType: "text/event-stream; charset=utf-8")
            == .object(["ok": .bool(true)]))
    }

    @Test("A JSON-RPC error and an answer to another request are failures")
    func protocolFailuresAreReported() {
        let error = Data(#"{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"Method not found"}}"#.utf8)
        #expect(throws: MCPLoopbackHTTPError.rpc(code: -32_601, message: "Method not found")) {
            try MCPLoopbackHTTPClient.result(forID: 3, in: error, contentType: "application/json")
        }
        let other = Data(#"{"jsonrpc":"2.0","id":4,"result":{}}"#.utf8)
        #expect(throws: MCPLoopbackHTTPError.self) {
            try MCPLoopbackHTTPClient.result(forID: 3, in: other, contentType: nil)
        }
    }

    @Test("Advertised tools keep their name, description, and schema")
    func toolsAreParsed() {
        let result: MCPJSONValue = .object(["tools": .array([
            .object(["name": .string("get_scene"), "description": .string("Reads the scene")]),
            .object(["description": .string("nameless entries are skipped")])
        ])])
        let tools = MCPLoopbackHTTPClient.parseTools(result)
        #expect(tools.map(\.name) == ["get_scene"])
        #expect(tools.first?.description == "Reads the scene")
    }

    // MARK: Results for the model

    @Test("Text blocks are joined and an error is marked")
    func textOutcome() async {
        let result = MCPToolResult(
            content: [
                .object(["type": .string("text"), "text": .string("one")]),
                .object(["type": .string("text"), "text": .string("two")])
            ],
            structuredContent: nil,
            isError: true
        )
        #expect(await ConnectorTool.outcome(for: result, supportsVision: { true }) == .message("Tool error:\none\ntwo"))
    }

    @Test("An image is never rendered as text for a model that cannot see")
    func imageBytesNeverBecomeText() async {
        let payload = Data(repeating: 0x41, count: 4_096).base64EncodedString()
        let result = MCPToolResult(
            content: [
                .object(["type": .string("text"), "text": .string("front view")]),
                .object(["type": .string("image"), "data": .string(payload), "mimeType": .string("image/png")])
            ],
            structuredContent: nil,
            isError: false
        )
        guard case .message(let text) = await ConnectorTool.outcome(for: result, supportsVision: { false }) else {
            Issue.record("A model without vision must receive text only")
            return
        }
        #expect(text.hasPrefix("front view"))
        #expect(text.contains("cannot see images"))
        #expect(!text.contains(payload.prefix(64)))
    }

    @Test("Very long text is cut instead of filling the context")
    func longTextIsTruncated() async {
        let result = MCPToolResult(
            content: [.object(["type": .string("text"), "text": .string(String(repeating: "x", count: 50_000))])],
            structuredContent: nil,
            isError: false
        )
        guard case .message(let text) = await ConnectorTool.outcome(for: result, supportsVision: { true }) else {
            Issue.record("Text only results are messages")
            return
        }
        #expect(text.count < ConnectorTool.maximumTextCharacters + 100)
        #expect(text.hasSuffix("[output truncated]"))
    }

    @Test("A session with one connector does not need to name it, and cannot reach another")
    func connectorIsResolvedWithinTheSession() async {
        let tool = ConnectorTool(connectors: [MCPConnectorCatalog.prassitele], supportsVision: { false })
        let unknown = await tool.run(arguments: ConnectorArguments(
            connector: "safari", operation: "list_tools", toolName: nil, argumentsJSON: nil
        ))
        #expect(unknown == .message("Unknown connector. This session has: prassitele."))

        let badArguments = await tool.run(arguments: ConnectorArguments(
            connector: nil, operation: "call", toolName: "get_scene", argumentsJSON: "[1]"
        ))
        #expect(badArguments == .message("argumentsJSON must be a valid JSON object."))
    }

    // MARK: Skills

    @Test("A connector's skill is bundled, parses, and never tells the model to use a host shell")
    @MainActor
    func connectorSkillIsBundledAndHostFree() throws {
        let skills = MCPConnectorCatalog.skills(for: [MCPConnectorCatalog.prassitele])
        let skill = try #require(skills.first)
        #expect(skill.name == "prassitele-sculpting")
        #expect(skill.prompt.contains("`connector` tool"))
        for forbidden in ["bust.py", "sessions.py", "with Bash", "python3"] {
            #expect(!skill.prompt.contains(forbidden), "The skill still mentions \(forbidden)")
        }
        #expect(MCPConnectorCatalog.skills(for: []).isEmpty)
    }

    @Test("Connector skills join the catalog without replacing a skill the user installed")
    @MainActor
    func connectorSkillsDoNotReplaceUserSkills() throws {
        let offered = try #require(MCPConnectorCatalog.skills(for: [MCPConnectorCatalog.prassitele]).first)
        #expect(MCPConnectorCatalog.catalog(adding: [offered], to: []).map(\.name) == ["prassitele-sculpting"])
        #expect(MCPConnectorCatalog.catalog(adding: [offered], to: [offered]).count == 1)
    }

    // MARK: Persistence

    @Test("Sessions saved before connectors decode with none, and a choice survives a save")
    func connectorsPersistWithTheSession() throws {
        var stored = StoredSession(title: "Bust", projectName: "_general", domain: .cowork)
        #expect(stored.connectors == nil)
        let legacy = try JSONEncoder().encode(stored)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("connectors"))
        #expect(try JSONDecoder().decode(StoredSession.self, from: legacy).connectors == nil)

        stored.connectors = ["prassitele"]
        let decoded = try JSONDecoder().decode(StoredSession.self, from: try JSONEncoder().encode(stored))
        #expect(decoded.connectors == ["prassitele"])
        #expect(Conversation(title: "New").connectors.isEmpty)
    }
}
