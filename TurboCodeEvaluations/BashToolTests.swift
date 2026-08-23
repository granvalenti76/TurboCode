import Foundation
import Testing
@testable import TurboCode

@Suite("Bash tool")
struct BashToolTests {
    @Test("Bash can build and install workspace plugin files", .timeLimit(.minutes(1)))
    func bashCanBuildAndInstallWorkspacePluginFiles() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspace = repositoryRoot
            .appendingPathComponent(".BashToolTests-\(UUID().uuidString)", isDirectory: true)
        let sources = workspace.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App", targets: [.executableTarget(name: "App")])
        """.write(
            to: workspace.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "print(\"ok\")\n".write(
            to: sources.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )

        let pluginRoot = workspace.appendingPathComponent("InstalledPlugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginRoot, withIntermediateDirectories: true)
        let tool = BashTool(
            workspaceRoot: workspace.path,
            pluginRoot: pluginRoot.path,
            sdkRoot: workspace.path
        )
        let output = try await tool.call(
            arguments: BashArguments(command: "swift build", timeoutSeconds: 50, maxOutputCharacters: 12_000)
        )

        #expect(output.contains("Exit code: 0"))
        #expect(!output.contains("not accessible or not writable"))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".build").path))

        let workspaceWrite = try await tool.call(
            arguments: BashArguments(
                command: "printf overwritten > Sources/App/main.swift",
                timeoutSeconds: 10,
                maxOutputCharacters: 4_000
            )
        )
        #expect(workspaceWrite.contains("Exit code: 0"))
        #expect(try String(contentsOf: sources.appendingPathComponent("main.swift"), encoding: .utf8) == "overwritten")

        let pluginWrite = try await tool.call(
            arguments: BashArguments(
                command: "mkdir -p \"$TURBOCODE_PLUGIN_ROOT/demo\" && printf '{\"id\":\"demo\"}' > \"$TURBOCODE_PLUGIN_ROOT/demo/plugin.json\"",
                timeoutSeconds: 10,
                maxOutputCharacters: 4_000
            )
        )
        #expect(pluginWrite.contains("Exit code: 0"))
        #expect(FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent("demo/plugin.json").path))
    }
}
