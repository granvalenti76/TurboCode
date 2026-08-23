import Foundation
import Testing
@testable import TurboCode

@Suite("TypeScript plugin project service")
struct TypeScriptPluginProjectServiceTests {
    @Test("Bootstraps the compiled SDK package at the canonical local path")
    func bootstrapsSDKPackage() throws {
        let root = try makeRoot("SDK")
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("sdk-source", isDirectory: true)
        try writeSDKPackage(at: source)
        let destination = root.appendingPathComponent(".turbocode", isDirectory: true)
        let service = TypeScriptPluginProjectService(
            pluginsRoot: destination.appendingPathComponent("plugins", isDirectory: true),
            sdkRoot: destination.appendingPathComponent("sdk", isDirectory: true)
        )

        let installed = try service.bootstrapSDK(from: source)

        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("package.json").path))
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("dist/index.js").path))
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("src/index.ts").path))
    }

    @Test("Builds a project and atomically stages its runtime files")
    func buildsAndStagesRuntime() async throws {
        let root = try makeRoot("Import")
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("project", isDirectory: true)
        try writeProject(at: project)
        let sdk = root.appendingPathComponent("sdk", isDirectory: true)
        try writeSDKPackage(at: sdk)
        let node = try makeExecutable(at: root.appendingPathComponent("node"))
        _ = try makeExecutable(at: node.deletingLastPathComponent().appendingPathComponent("npm"))
        let recorder = CommandRecorder()
        let runner = makeRunner(recorder: recorder)
        let pluginsRoot = root.appendingPathComponent("plugins", isDirectory: true)
        let service = TypeScriptPluginProjectService(
            pluginsRoot: pluginsRoot,
            sdkRoot: root.appendingPathComponent("installed-sdk", isDirectory: true),
            nodeExecutableURL: node,
            commandRunner: runner
        )

        let receipt = try await service.buildAndImport(
            projectRoot: project,
            sdkPackageURL: sdk
        )
        let calls = await recorder.calls

        #expect(receipt.pluginID == "sample-plugin")
        #expect(!receipt.replacedExistingInstallation)
        #expect(receipt.commands == [
            "tsc --noEmit",
            "npm run build",
            "npm run lint --if-present"
        ])
        #expect(calls.map(\.arguments) == [
            ["--version"],
            ["exec", "--", "tsc", "--noEmit"],
            ["run", "build"],
            ["run", "--if-present", "lint"]
        ])
        #expect(FileManager.default.fileExists(
            atPath: receipt.installedRoot.appendingPathComponent("dist/index.js").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: receipt.installedRoot.appendingPathComponent(
                "node_modules/@granvalenti/turbocode-sdk/dist/index.js"
            ).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: receipt.installedRoot.appendingPathComponent("src/index.ts").path
        ))
    }

    @Test("Preserves the previous installation when the build fails")
    func preservesPreviousInstallationOnBuildFailure() async throws {
        let root = try makeRoot("Failure")
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("project", isDirectory: true)
        try writeProject(at: project)
        let previous = root.appendingPathComponent("plugins/sample-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data("previous-generation".utf8)
            .write(to: previous.appendingPathComponent("generation.txt"))
        let node = try makeExecutable(at: root.appendingPathComponent("node"))
        _ = try makeExecutable(at: node.deletingLastPathComponent().appendingPathComponent("npm"))
        let recorder = CommandRecorder()
        let runner = makeRunner(recorder: recorder, failBuild: true)
        let service = TypeScriptPluginProjectService(
            pluginsRoot: root.appendingPathComponent("plugins", isDirectory: true),
            sdkRoot: root.appendingPathComponent("sdk", isDirectory: true),
            nodeExecutableURL: node,
            commandRunner: runner
        )

        await #expect(throws: TypeScriptPluginProjectError.self) {
            try await service.buildAndImport(projectRoot: project)
        }

        #expect(String(
            data: try Data(contentsOf: previous.appendingPathComponent("generation.txt")),
            encoding: .utf8
        ) == "previous-generation")
    }

    private struct CommandCall: Sendable, Equatable {
        let executable: URL
        let arguments: [String]
        let workingDirectory: URL
    }

    private actor CommandRecorder {
        var calls: [CommandCall] = []

        func record(_ call: CommandCall) {
            calls.append(call)
        }
    }

    private func makeRunner(
        recorder: CommandRecorder,
        failBuild: Bool = false
    ) -> TypeScriptPluginProjectService.CommandRunner {
        { executable, arguments, workingDirectory, _ in
            await recorder.record(
                CommandCall(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: workingDirectory
                )
            )
            if arguments == ["--version"] {
                return TypeScriptPluginCommandResult(
                    exitCode: 0,
                    standardOutput: "v24.0.0\n"
                )
            }
            if failBuild, arguments == ["run", "build"] {
                return TypeScriptPluginCommandResult(
                    exitCode: 1,
                    standardError: "TypeScript compilation failed"
                )
            }
            if arguments == ["run", "build"] {
                let dist = workingDirectory.appendingPathComponent("dist", isDirectory: true)
                try? FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
                try? Data("compiled".utf8).write(
                    to: dist.appendingPathComponent("index.js")
                )
            }
            return TypeScriptPluginCommandResult(exitCode: 0)
        }
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-TypeScriptProject-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(at url: URL) throws -> URL {
        try Data().write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    private func writeProject(at root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
        let manifest = TypeScriptPluginManifest(
            id: "sample-plugin",
            name: "Sample Plugin",
            version: "0.1.0",
            entrypoint: "dist/index.js",
            tools: [
                TypeScriptPluginToolManifest(
                    name: "echo",
                    description: "Echo",
                    inputSchema: .object(["type": .string("object")])
                )
            ]
        )
        try JSONEncoder().encode(manifest)
            .write(to: root.appendingPathComponent("plugin.json"))
        try Data("source".utf8)
            .write(to: root.appendingPathComponent("src/index.ts"))
    }

    private func writeSDKPackage(at root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("dist", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{\"name\":\"@granvalenti/turbocode-sdk\"}".utf8)
            .write(to: root.appendingPathComponent("package.json"))
        try Data("compiled sdk".utf8)
            .write(to: root.appendingPathComponent("dist/index.js"))
        try Data("source sdk".utf8)
            .write(to: root.appendingPathComponent("src/index.ts"))
    }
}
