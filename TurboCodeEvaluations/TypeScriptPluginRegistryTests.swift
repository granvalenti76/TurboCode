import Foundation
import Testing
@testable import TurboCode

@Suite("TypeScript plugin registry")
struct TypeScriptPluginRegistryTests {
    @Test("Discovers installed plugins without starting Node")
    func discoversInstalledPlugins() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-PluginRegistry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("one", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("two", isDirectory: true),
            withIntermediateDirectories: true
        )

        try writeManifest(id: "one", at: root.appendingPathComponent("one"))
        try writeManifest(id: "two", at: root.appendingPathComponent("two"))

        let registry = TypeScriptPluginRegistry(
            pluginsRoot: root
        )
        let result = registry.discover()

        #expect(result.failures.isEmpty)
        #expect(result.plugins.map { $0.manifest.id } == ["one", "two"])
        #expect(result.plugins.flatMap(\.toolIDs).map(\.rawValue) == ["one/echo", "two/echo"])
    }

    @Test("Reports invalid plugin metadata without hiding valid plugins")
    func reportsInvalidMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-PluginRegistry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalid = root.appendingPathComponent("invalid", isDirectory: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("{\"manifestVersion\":99}".utf8)
            .write(to: invalid.appendingPathComponent("plugin.json"))

        let result = TypeScriptPluginRegistry(
            pluginsRoot: root
        ).discover()

        #expect(result.plugins.isEmpty)
        #expect(result.failures.count == 1)
    }

    private func writeManifest(id: String, at root: URL) throws {
        let entrypoint = root.appendingPathComponent("index.js")
        try Data("// test fixture\n".utf8).write(to: entrypoint)
        let manifest = TypeScriptPluginManifest(
            id: id,
            name: "Plugin \(id)",
            version: "0.1.0",
            entrypoint: "index.js",
            tools: [
                TypeScriptPluginToolManifest(
                    name: "echo",
                    description: "Echo",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object(["value": .object(["type": .string("string")])]),
                        "required": .array([.string("value")])
                    ])
                )
            ]
        )
        try JSONEncoder().encode(manifest)
            .write(to: root.appendingPathComponent("plugin.json"))
    }
}
