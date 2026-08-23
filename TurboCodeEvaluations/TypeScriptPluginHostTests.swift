import Foundation
import Testing
@testable import TurboCode

@Suite("TypeScript plugin host")
struct TypeScriptPluginHostTests {
    @Test("Frames partial JSONL records without starting a process")
    func framesPartialRecords() {
        var buffer = Data("{\"id\":1,\"result\"".utf8)

        #expect(TypeScriptPluginHost.framedLines(from: &buffer).isEmpty)

        buffer.append(Data(": {\"text\":\"ok\"}}\r\n{\"id\":2}".utf8))
        #expect(
            TypeScriptPluginHost.framedLines(from: &buffer)
                == ["{\"id\":1,\"result\": {\"text\":\"ok\"}}"]
        )
        #expect(String(data: buffer, encoding: .utf8) == "{\"id\":2}")
    }

    @Test("A validated plugin starts Node lazily and completes a tool call")
    func startsNodeLazilyAndCallsTool() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let node = try NodeRuntimeResolver.resolve(
            policy: NodeRuntimePolicy(explicitExecutableURL: fixture.nodeURL)
        )
        let major = try nodeMajor(executable: node)
        let host = TypeScriptPluginHost(
            configuration: TypeScriptPluginHostConfiguration(
                manifest: fixture.manifest,
                pluginRoot: fixture.root,
                nodePolicy: NodeRuntimePolicy(
                    supportedMajor: major,
                    explicitExecutableURL: node
                )
            )
        )

        #expect(await !host.isRunning())
        let handshake = try await host.start()
        #expect(await host.isRunning())
        #expect(handshake.pluginID == "echo-plugin")
        #expect(handshake.tools == ["echo"])

        let result = try await host.call(
            tool: "echo",
            arguments: .object(["value": .string("hello")])
        )
        #expect(result.text == "hello")
        #expect(result.widget == nil)

        await host.shutdown()
        #expect(await !host.isRunning())
    }

    @Test("Widget results survive the model text envelope")
    func widgetResultEnvelopeRoundTrips() throws {
        let widget = TypeScriptPluginWidgetReceipt(
            pluginID: "demo",
            widgetID: "dashboard",
            title: "Dashboard",
            entrypoint: "dist/widget.html",
            pluginRoot: "/tmp/demo",
            props: .object(["value": .integer(3)])
        )
        let result = TypeScriptPluginToolResultEnvelope(
            text: "Dashboard ready",
            isError: false,
            widget: widget
        )

        let encoded = TypeScriptPluginToolResultCodec.encodeForModel(result)
        #expect(TypeScriptPluginToolResultCodec.visibleText(encoded) == "Dashboard ready")
        #expect(TypeScriptPluginToolResultCodec.decode(encoded) == result)
    }

    @Test("The host rejects a Node version outside its policy")
    func rejectsIncompatibleNodeVersion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let node = try NodeRuntimeResolver.resolve(
            policy: NodeRuntimePolicy(explicitExecutableURL: fixture.nodeURL)
        )
        let major = try nodeMajor(executable: node)
        let host = TypeScriptPluginHost(
            configuration: TypeScriptPluginHostConfiguration(
                manifest: fixture.manifest,
                pluginRoot: fixture.root,
                nodePolicy: NodeRuntimePolicy(
                    supportedMajor: major + 1,
                    explicitExecutableURL: node
                )
            )
        )

        do {
            _ = try await host.start()
            Issue.record("The incompatible Node process was accepted")
        } catch let error as NodeRuntimeError {
            guard case let .incompatibleVersion(_, requiredMajor) = error,
                  requiredMajor == major + 1 else {
                Issue.record("Unexpected Node resolver error: \(error)")
                return
            }
        } catch let error as TypeScriptPluginHostError {
            guard case .handshakeFailed = error else {
                Issue.record("Unexpected plugin host error: \(error)")
                return
            }
        }
    }

    @Test("A plugin can request a read-only snapshot of the active session")
    func pluginCanReadSessionTranscript() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let node = try NodeRuntimeResolver.resolve(
            policy: NodeRuntimePolicy(explicitExecutableURL: fixture.nodeURL)
        )
        let major = try nodeMajor(executable: node)
        let transcript: PluginJSONValue = .object([
            "sessionID": .string("session-1"),
            "title": .string("Plugin API"),
            "updatedAt": .string("2026-08-22T10:00:00.000Z"),
            "entries": .array([
                .object([
                    "id": .string("entry-1"),
                    "kind": .string("user"),
                    "text": .string("remember this decision"),
                    "createdAt": .string("2026-08-22T09:59:00.000Z"),
                    "model": .null,
                    "providerID": .null
                ])
            ])
        ])
        let host = TypeScriptPluginHost(
            configuration: TypeScriptPluginHostConfiguration(
                manifest: fixture.manifest,
                pluginRoot: fixture.root,
                nodePolicy: NodeRuntimePolicy(
                    supportedMajor: major,
                    explicitExecutableURL: node
                ),
                sessionTranscript: { transcript }
            )
        )

        _ = try await host.start()
        let result = try await host.call(
            tool: "echo",
            arguments: .object([
                "value": .string("ignored"),
                "readSession": .bool(true)
            ])
        )

        #expect(result.text.contains("remember this decision"))
        await host.shutdown()
    }

    @Test("Manifest rejects a runtime below the supported Node minimum")
    func rejectsUnsupportedManifestRuntime() throws {
        let fixture = try makeFixture(
            runtime: TypeScriptPluginRuntime(node: "22.x")
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            try fixture.manifest.validate(at: fixture.root)
            Issue.record("The unsupported runtime declaration was accepted")
        } catch let error as TypeScriptPluginManifestError {
            #expect(error == .unsupportedNodeRange("22.x"))
        }
    }

    @Test("Manifest accepts the open Node minimum range")
    func acceptsOpenNodeRange() throws {
        let fixture = try makeFixture(
            runtime: TypeScriptPluginRuntime(node: ">=24.0.0")
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try fixture.manifest.validate(at: fixture.root)
    }

    private struct Fixture {
        let root: URL
        let nodeURL: URL
        let manifest: TypeScriptPluginManifest
    }

    private func makeFixture(
        runtime: TypeScriptPluginRuntime = .init()
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-TypeScriptPlugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let script = root.appendingPathComponent("index.js")
        try """
        const readline = require('node:readline');
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        const waiting = new Map();
        function reply(id, result) {
          process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\\n');
        }
        rl.on('line', (line) => {
          const message = JSON.parse(line);
          if (!message.method && waiting.has(message.id)) {
            const toolID = waiting.get(message.id);
            waiting.delete(message.id);
            reply(toolID, { text: JSON.stringify(message.result) });
            return;
          }
          if (message.method === 'initialize') {
            reply(message.id, {
              protocolVersion: 1,
              pluginID: process.env.TURBOCODE_PLUGIN_ID,
              nodeVersion: process.version,
              tools: ['echo']
            });
          } else if (message.method === 'tools/call') {
            if (message.params.arguments.readSession) {
              const requestID = 'plugin-session-1';
              waiting.set(requestID, message.id);
              process.stdout.write(JSON.stringify({
                jsonrpc: '2.0',
                id: requestID,
                method: 'session/readTranscript'
              }) + '\\n');
            } else {
              reply(message.id, { text: message.params.arguments.value });
            }
          }
        });
        """.write(to: script, atomically: true, encoding: .utf8)

        let manifest = TypeScriptPluginManifest(
            id: "echo-plugin",
            name: "Echo Plugin",
            version: "0.1.0",
            entrypoint: "index.js",
            runtime: runtime,
            tools: [
                TypeScriptPluginToolManifest(
                    name: "echo",
                    description: "Echo a string.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "value": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("value")])
                    ])
                )
            ]
        )
        let node = try localNodeURL()
        return Fixture(root: root, nodeURL: node, manifest: manifest)
    }

    private func localNodeURL() throws -> URL {
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ].map(URL.init(fileURLWithPath:))
        let nvmRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil
        ) {
            candidates += versions
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin/node") }
        }
        if let node = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return node
        }
        throw NSError(domain: "TypeScriptPluginHostTests", code: 2)
    }

    private func nodeMajor(executable: URL) throws -> Int {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let version = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let major = version
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: ".")
            .first
        guard let major, let value = Int(major) else {
            throw NSError(domain: "TypeScriptPluginHostTests", code: 1)
        }
        return value
    }
}
