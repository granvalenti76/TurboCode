import Foundation
import Darwin
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

    @Test("ACP MCP environment accepts standard entries and rejects invalid declarations")
    func acpEnvironmentValidation() throws {
        let base: [String: MCPJSONValue] = [
            "name": .string("fixture-server"),
            "command": .string("fixture-server")
        ]
        let standard = try ACPMCPServerConfiguration(
            value: .object(base.merging([
                "env": .array([
                    .object(["name": .string("ACP_FIXTURE"), "value": .string("")]),
                    .object(["name": .string("PATH_OVERRIDE"), "value": .string("/tmp")])
                ])
            ]) { _, new in new }),
            cwd: "/"
        )
        #expect(standard.environment == ["ACP_FIXTURE": "", "PATH_OVERRIDE": "/tmp"])

        let absent = try ACPMCPServerConfiguration(value: .object(base), cwd: "/")
        #expect(absent.environment.isEmpty)
        let empty = try ACPMCPServerConfiguration(
            value: .object(base.merging(["env": .array([])]) { _, new in new }),
            cwd: "/"
        )
        #expect(empty.environment.isEmpty)

        let object = base.merging(["env": .object(["ACP_FIXTURE": .string("legacy")])]) { _, new in new }
        #expect(throws: ACPApplicationRuntimeError.invalidConfiguration(
            "ACP MCP server 'fixture-server' environment must be an array."
        )) {
            _ = try ACPMCPServerConfiguration(value: .object(object), cwd: "/")
        }

        let duplicate = base.merging([
            "env": .array([
                .object(["name": .string("DUPLICATE"), "value": .string("one")]),
                .object(["name": .string("DUPLICATE"), "value": .string("two")])
            ])
        ]) { _, new in new }
        #expect(throws: ACPApplicationRuntimeError.invalidConfiguration(
            "ACP MCP server 'fixture-server' has duplicate environment name 'DUPLICATE'."
        )) {
            _ = try ACPMCPServerConfiguration(value: .object(duplicate), cwd: "/")
        }
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
            "env": .array([
                .object([
                    "name": .string("ACP_FIXTURE"),
                    "value": .string("environment-preserved")
                ])
            ]),
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

    @Test("ACP MCP setup failure stops the current child and repeated stop is safe")
    func failedSetupStopsCurrentProcess() async throws {
        let fixture = MCPProcessFixture(name: "failed-setup", mode: "error")
        defer { fixture.cleanup() }
        let runtime = ACPMCPRuntime()

        do {
            _ = try await runtime.start(
                declarations: [fixture.declaration],
                cwd: "/"
            )
            Issue.record("Expected tools/list setup to fail")
        } catch {
            // The process marker below is the observable cleanup contract.
        }

        #expect(await fixture.waitForExit())
        await runtime.stop()
        await runtime.stop()
    }

    @Test("ACP MCP stop during setup stops the in-flight child")
    func stopDuringSetupStopsCurrentProcess() async throws {
        let fixture = MCPProcessFixture(name: "slow-setup", mode: "slow")
        defer { fixture.cleanup() }
        let runtime = ACPMCPRuntime()
        let setup = Task {
            try await runtime.start(
                declarations: [fixture.declaration],
                cwd: "/"
            )
        }

        #expect(await fixture.waitForStart())
        await runtime.stop()
        do {
            _ = try await setup.value
            Issue.record("Expected setup to be interrupted")
        } catch {
            // Stopping the runtime must unwind the setup request.
        }
        #expect(await fixture.waitForExit())
    }

    @Test("ACP MCP failure stops already registered and in-flight children")
    func failedSecondSetupStopsAllChildren() async throws {
        let first = MCPProcessFixture(name: "first-server", mode: "success")
        let second = MCPProcessFixture(name: "second-server", mode: "error")
        defer {
            first.cleanup()
            second.cleanup()
        }
        let runtime = ACPMCPRuntime()

        do {
            _ = try await runtime.start(
                declarations: [first.declaration, second.declaration],
                cwd: "/"
            )
            Issue.record("Expected the second tools/list request to fail")
        } catch {
            // Both fixture exit markers must be observed before the test ends.
        }

        #expect(await first.waitForExit())
        #expect(await second.waitForExit())
        await runtime.stop()
    }

    @Test("ACP MCP alias collision stops the child started for the rejected alias")
    func aliasCollisionStopsCurrentProcess() async throws {
        let first = MCPProcessFixture(name: "alias-server", mode: "success")
        let second = MCPProcessFixture(name: "alias_server", mode: "success")
        defer {
            first.cleanup()
            second.cleanup()
        }
        let runtime = ACPMCPRuntime()

        do {
            _ = try await runtime.start(
                declarations: [first.declaration, second.declaration],
                cwd: "/"
            )
            Issue.record("Expected the normalized MCP aliases to collide")
        } catch {
            // Alias rejection must still release both owned processes.
        }

        #expect(await first.waitForExit())
        #expect(await second.waitForExit())
        await runtime.stop()
    }
}

private struct MCPProcessFixture {
    let declaration: MCPJSONValue
    private let pidURL: URL
    private let exitURL: URL

    init(name: String, mode: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCodeMCP-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        pidURL = root.appendingPathComponent("pid")
        exitURL = root.appendingPathComponent("exit")
        let script = #"""
        import json, os, signal, sys, time

        pid_path, exit_path, mode = sys.argv[1:4]
        with open(pid_path, "w") as marker:
            marker.write(str(os.getpid()))

        def mark_exit(signum, frame):
            with open(exit_path, "w") as marker:
                marker.write("exited")
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, mark_exit)
        if mode == "slow":
            time.sleep(1.5)
        try:
            for line in sys.stdin:
                request = json.loads(line)
                method = request.get("method")
                if method.startswith("notifications/"):
                    continue
                if method == "initialize":
                    result = {"protocolVersion": "2025-06-18"}
                    response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
                elif method == "tools/list" and mode == "error":
                    response = {"jsonrpc": "2.0", "id": request["id"], "error":
                        {"code": -32001, "message": "fixture tools/list failure"}}
                elif method == "tools/list":
                    response = {"jsonrpc": "2.0", "id": request["id"], "result": {"tools": []}}
                else:
                    response = {"jsonrpc": "2.0", "id": request["id"], "result": {}}
                print(json.dumps(response), flush=True)
        finally:
            with open(exit_path, "w") as marker:
                marker.write("exited")
        """#
        self.declaration = .object([
            "name": .string(name),
            "command": .string("/usr/bin/python3"),
            "args": .array([
                .string("-c"),
                .string(script),
                .string(pidURL.path),
                .string(exitURL.path),
                .string(mode)
            ]),
            "cwd": .string("/tmp")
        ])
    }

    func waitForExit() async -> Bool {
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: exitURL.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func waitForStart() async -> Bool {
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: pidURL.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func cleanup() {
        if let pid = try? String(contentsOf: pidURL, encoding: .utf8),
           let processID = Int32(pid.trimmingCharacters(in: .whitespacesAndNewlines)) {
            _ = kill(processID, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidURL.deletingLastPathComponent())
    }
}
