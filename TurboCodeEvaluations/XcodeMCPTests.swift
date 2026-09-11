import Foundation
import Testing
@testable import TurboCode

@Suite("Xcode MCP")
struct XcodeMCPTests {
    @Test("MCP JSON keeps nested schemas and rich content intact")
    func jsonValuePreservesNestedValues() throws {
        let value: MCPJSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "options": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ])
            ])
        ])

        let decoded = try JSONDecoder().decode(
            MCPJSONValue.self,
            from: JSONEncoder().encode(value)
        )

        #expect(decoded == value)
        #expect(decoded.jsonString.contains("options"))
        #expect(decoded.jsonString.contains("items"))
    }

    @Test("MCP tool results preserve error status and non-text content")
    func toolResultPreservesErrorAndContent() {
        let result = MCPToolResult(
            content: [
                .object([
                    "type": .string("image"),
                    "data": .string("encoded-image"),
                    "mimeType": .string("image/png")
                ])
            ],
            structuredContent: .object([
                "diagnostics": .array([.string("warning")])
            ]),
            isError: true
        )

        #expect(result.isError)
        #expect(result.text.contains("image"))
        #expect(result.renderedForModel.hasPrefix("MCP tool error:"))
        #expect(result.renderedForModel.contains("diagnostics"))
    }

    @Test("Xcode MCP is disabled by default and for legacy configuration")
    func defaultsToDisabled() throws {
        #expect(!AgentTuningConfig.default.experimental.xcodeMCPEnabled)
        let decoded = try JSONDecoder().decode(
            AgentTuningConfig.self,
            from: Data(#"{"schemaVersion":1,"experimental":{}}"#.utf8)
        )
        #expect(!decoded.experimental.xcodeMCPEnabled)
    }

    @Test("Xcode MCP capability requires opt-in and never reaches workers")
    func capabilityIsGated() {
        let disabled = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .standard,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: true,
                hasDelegateModel: false,
                repositoryMapDetail: nil
            )
        )
        #expect(!disabled.registeredIDs.contains(.xcodeMCP))

        let enabled = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .standard,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: true,
                xcodeMCPEnabled: true,
                hasDelegateModel: false,
                repositoryMapDetail: nil
            )
        )
        #expect(enabled.registeredIDs.contains(.xcodeMCP))

        let worker = ModelToolCatalog.plan(
            profile: .delegate,
            tier: .standard,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: true,
                xcodeMCPEnabled: true,
                hasDelegateModel: true,
                repositoryMapDetail: nil
            )
        )
        #expect(!worker.registeredIDs.contains(.xcodeMCP))
    }

    @Test("Codex advertises the Xcode MCP gateway only when enabled")
    func codexSpecificationIsGated() {
        let disabled = CodexTurboCodeToolBridge.specifications(
            workspaceRoot: "/tmp/workspace",
            agentTuning: .default
        )
        #expect(!disabled.contains { $0.name == ToolCapabilityID.xcodeMCP.rawValue })

        let tuning = AgentTuningConfig(
            experimental: ExperimentalPolicy(xcodeMCPEnabled: true)
        )
        let enabled = CodexTurboCodeToolBridge.specifications(
            workspaceRoot: "/tmp/workspace",
            agentTuning: tuning,
            xcodeMCPEnabled: true
        )
        #expect(enabled.contains { $0.name == ToolCapabilityID.xcodeMCP.rawValue })
    }

    @Test("Disabled gateway does not start the Xcode bridge")
    func disabledGatewayIsInert() async throws {
        let tool = XcodeMCPTool(enabled: false)
        let output = try await tool.call(
            arguments: XcodeMCPArguments(
                operation: "list_tools",
                toolName: nil,
                argumentsJSON: nil
            )
        )
        #expect(output.contains("disabled"))
    }

    @Test("ACP MCP stdio preserves session command environment and tool calls")
    func acpStdioRuntime() async throws {
        let serverScript = #"""
        import json, os, sys

        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method.startswith("notifications/"):
                continue
            result = {}
            if method == "initialize":
                result = {"protocolVersion": "2025-06-18"}
            elif method == "tools/list":
                result = {"tools": [{
                    "name": "echo",
                    "description": "Echo fixture",
                    "inputSchema": {"type": "object"}
                }]}
            elif method == "tools/call":
                value = request["params"]["arguments"]["value"]
                result = {"content": [{"type": "text", "text":
                    f"{os.environ.get('ACP_FIXTURE')}:{os.getcwd()}:{sys.argv[1]}:{value}"
                }]}
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        """#
        let declaration: MCPJSONValue = .object([
            "name": .string("fixture-server"),
            "command": .string("/usr/bin/python3"),
            "args": .array([
                .string("-c"),
                .string(serverScript),
                .string("argument-preserved")
            ]),
            "env": .object(["ACP_FIXTURE": .string("environment-preserved")]),
            "cwd": .string("/tmp")
        ])

        let runtime = ACPMCPRuntime()
        let tools = try await runtime.start(declarations: [declaration], cwd: "/")
        let tool = try #require(tools.first as? ACPMCPTool)
        let output = try await tool.call(arguments: ACPMCPToolArguments(
            operation: "call",
            toolName: "echo",
            argumentsJSON: #"{"value":"payload-preserved"}"#
        ))
        await runtime.stop()

        #expect(tools.count == 1)
        #expect(output.contains("environment-preserved:"))
        #expect(output.contains("/tmp:argument-preserved:payload-preserved"))
    }
}
