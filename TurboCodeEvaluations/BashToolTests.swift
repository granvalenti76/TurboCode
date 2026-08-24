import Foundation
import Testing
@testable import TurboCode

@Suite("Bash tool")
struct BashToolTests {
    @Test("Bash exposes only the SDK package locator")
    func bashExposesOnlySDKPackageLocator() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-BashSDKEnvironment-\(UUID().uuidString)", isDirectory: true)
        let sdkRoot = workspace.appendingPathComponent("sdk", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tool = BashTool(workspaceRoot: workspace.path, sdkRoot: sdkRoot.path)

        let output = try await tool.call(
            arguments: BashArguments(
                command: "test -z \"${TURBOCODE_SDK_ROOT+x}\" && test -z \"${TURBOCODE_PLUGIN_ROOT+x}\" && test -z \"${TURBOCODE_NODE_PATH+x}\" && printf '%s' \"$TURBOCODE_SDK_PACKAGE\"",
                timeoutSeconds: 10,
                maxOutputCharacters: 4_000
            )
        )

        #expect(output.contains("Exit code: 0"))
        #expect(output.contains(
            sdkRoot.appendingPathComponent("@granvalenti/turbocode-sdk").path
        ))
    }

    @Test("The shell derives PWD from its process working directory")
    func shellDerivesWorkingDirectory() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-BashPWD-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tool = BashTool(workspaceRoot: workspace.path)

        let output = try await tool.call(
            arguments: BashArguments(
                command: "test \"$PWD\" = \"$(pwd)\" && printf '%s' \"$PWD\"",
                timeoutSeconds: 10,
                maxOutputCharacters: 4_000
            )
        )

        #expect(output.contains("Exit code: 0"))
        #expect(output.contains(workspace.path))
    }

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

        let shellHome = workspace.appendingPathComponent("ShellHome", isDirectory: true)
        let pluginRoot = shellHome.appendingPathComponent(
            ".turbocode/plugins",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: shellHome, withIntermediateDirectories: true)
        let tool = BashTool(
            workspaceRoot: workspace.path,
            sdkRoot: workspace.path,
            homeDirectory: shellHome.path
        )
        let output = try await tool.call(
            // The test requests SwiftPM's own sandbox policy explicitly; Bash
            // no longer rewrites commands or injects this flag on the model's behalf.
            arguments: BashArguments(
                command: "swift build --disable-sandbox",
                timeoutSeconds: 50,
                maxOutputCharacters: 12_000
            )
        )

        #expect(output.contains("Exit code: 0"))
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
                command: "mkdir -p ~/.turbocode/plugins/demo && printf '{\"id\":\"demo\"}' > ~/.turbocode/plugins/demo/plugin.json",
                timeoutSeconds: 10,
                maxOutputCharacters: 4_000
            )
        )
        #expect(pluginWrite.contains("Exit code: 0"))
        #expect(FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent("demo/plugin.json").path))
    }

    @Test("A missing workspace uses a disposable directory and requires approval for plugins")
    func missingWorkspaceDoesNotBecomeThePluginRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-BashTool-\(UUID().uuidString)", isDirectory: true)
        let shellHome = URL(fileURLWithPath: "/private/tmp/TurboCode-BashHome-\(UUID().uuidString)", isDirectory: true)
        let pluginRoot = shellHome.appendingPathComponent(".turbocode/plugins", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: shellHome)
        }

        let approvals = ApprovalCounter()
        let tool = BashTool(
            workspaceRoot: root.appendingPathComponent("deleted-workspace", isDirectory: true).path,
            sdkRoot: root.appendingPathComponent("sdk", isDirectory: true).path,
            homeDirectory: shellHome.path,
            requestApproval: { request in
                await approvals.increment()
                return await request.action()
            }
        )
        let relativeOutput = try await tool.call(
            arguments: BashArguments(
                command: "printf stray > marker.txt",
                timeoutSeconds: 10,
                maxOutputCharacters: 4_000
            )
        )

        #expect(relativeOutput.contains("Workspace unavailable"))
        #expect(!FileManager.default.fileExists(atPath: pluginRoot.appendingPathComponent("marker.txt").path))
        #expect(await approvals.value == 0)

        let pluginOutput = try await tool.call(
            arguments: BashArguments(
                command: "mkdir -p ~/.turbocode/plugins/reportistica && printf plugin > ~/.turbocode/plugins/reportistica/marker.txt",
                timeoutSeconds: 10,
                maxOutputCharacters: 4_000
            )
        )

        #expect(pluginOutput.contains("Exit code: 0"))
        #expect(await approvals.value == 1)
        #expect(try String(
            contentsOf: pluginRoot.appendingPathComponent("reportistica/marker.txt"),
            encoding: .utf8
        ) == "plugin")
    }

    @Test("Bash asks the host before accessing an external path")
    func bashRequiresHostApprovalOutsideAllowedRoots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-BashApproval-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let shellHome = root.appendingPathComponent("home", isDirectory: true)

        let externalFile = URL(fileURLWithPath: "/private/tmp/TurboCode-BashApproval-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalFile)
        }

        let approvals = ApprovalCounter()
        let tool = BashTool(
            workspaceRoot: workspace.path,
            sdkRoot: root.appendingPathComponent("sdk", isDirectory: true).path,
            homeDirectory: shellHome.path,
            requestApproval: { request in
                await approvals.increment()
                return await request.action()
            }
        )
        let output = try await tool.call(
            arguments: BashArguments(
                command: "printf approved > \(externalFile.path)",
                timeoutSeconds: 10,
                maxOutputCharacters: 4_000
            )
        )

        #expect(output.contains("Exit code: 0"))
        #expect(await approvals.value == 1)
        #expect(try String(contentsOf: externalFile, encoding: .utf8) == "approved")
    }
}

private actor ApprovalCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    var value: Int { count }
}
