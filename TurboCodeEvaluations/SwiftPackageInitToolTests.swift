import Foundation
import Testing
@testable import TurboCode

@Suite("Swift package init tool")
struct SwiftPackageInitToolTests {
    @Test("Creates an official executable package scaffold")
    func createsExecutablePackage() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tool = SwiftPackageInitTool(workspaceRoot: workspace.path, reportsChanges: false)

        let result = try await tool.call(
            arguments: SwiftPackageInitArguments(
                packageName: "TaskCLI",
                packageType: "executable"
            )
        )

        #expect(
            result.hasPrefix("SWIFT_PACKAGE_CREATED: TaskCLI (executable)"),
            Comment(rawValue: result)
        )
        let manifest = try String(
            contentsOf: workspace.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(manifest.contains("swift-tools-version:"))
        #expect(manifest.contains("name: \"TaskCLI\""))
        #expect(try containsSwiftSource(in: workspace.appendingPathComponent("Sources")))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".gitignore").path))
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".build").path))
    }

    @Test("Does not overwrite an existing workspace file")
    func rejectsConflictingFiles() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let manifest = workspace.appendingPathComponent("Package.swift")
        try "Existing manifest\n".write(to: manifest, atomically: true, encoding: .utf8)
        let tool = SwiftPackageInitTool(workspaceRoot: workspace.path, reportsChanges: false)

        let result = try await tool.call(
            arguments: SwiftPackageInitArguments(
                packageName: "TaskCLI",
                packageType: "executable"
            )
        )

        #expect(
            result.contains("would overwrite existing file(s): Package.swift"),
            Comment(rawValue: result)
        )
        #expect(try String(contentsOf: manifest, encoding: .utf8) == "Existing manifest\n")
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Sources").path))
    }

    @Test("Rejects invalid package names and template types")
    func rejectsInvalidArguments() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tool = SwiftPackageInitTool(workspaceRoot: workspace.path, reportsChanges: false)

        let invalidName = try await tool.call(
            arguments: SwiftPackageInitArguments(packageName: "../TaskCLI", packageType: "executable")
        )
        let invalidType = try await tool.call(
            arguments: SwiftPackageInitArguments(packageName: "TaskCLI", packageType: "application")
        )

        #expect(invalidName.contains("packageName must be"))
        #expect(invalidType.contains("packageType must be one of"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.path).isEmpty)
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-SwiftPackageInitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func containsSwiftSource(in directory: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        return enumerator.compactMap { $0 as? URL }.contains { $0.pathExtension == "swift" }
    }
}
