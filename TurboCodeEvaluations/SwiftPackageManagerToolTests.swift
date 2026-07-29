import Foundation
import Testing
@testable import TurboCode

@Suite("Swift Package Manager tool")
struct SwiftPackageManagerToolTests {
    @Test("Creates an official executable package scaffold")
    func createsExecutablePackage() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tool = SwiftPackageManagerTool(workspaceRoot: workspace.path, reportsChanges: false)

        let result = try await tool.call(
            arguments: SwiftPackageManagerArguments(
                action: "initialize",
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
        let tool = SwiftPackageManagerTool(workspaceRoot: workspace.path, reportsChanges: false)

        let result = try await tool.call(
            arguments: SwiftPackageManagerArguments(
                action: "initialize",
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
        let tool = SwiftPackageManagerTool(workspaceRoot: workspace.path, reportsChanges: false)

        let invalidName = try await tool.call(
            arguments: SwiftPackageManagerArguments(
                action: "initialize",
                packageName: "../TaskCLI",
                packageType: "executable"
            )
        )
        let invalidType = try await tool.call(
            arguments: SwiftPackageManagerArguments(
                action: "initialize",
                packageName: "TaskCLI",
                packageType: "application"
            )
        )

        #expect(invalidName.contains("packageName must be"))
        #expect(invalidType.contains("packageType must be one of"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.path).isEmpty)
    }

    @Test("Adds a dependency through a reviewable manifest edit")
    func addsDependencyToManifest() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App")
        """.write(
            to: workspace.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let tool = SwiftPackageManagerTool(workspaceRoot: workspace.path, reportsChanges: false)

        let result = try await tool.call(arguments: SwiftPackageManagerArguments(
            action: "addDependency",
            dependency: "https://example.com/ExampleKit.git",
            dependencyType: "url",
            requirement: "from",
            requirementValue: "1.2.0"
        ))

        let manifest = try String(
            contentsOf: workspace.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(result.hasPrefix("Applied 1 file change(s)"), Comment(rawValue: result))
        #expect(manifest.contains("https://example.com/ExampleKit.git"))
        #expect(manifest.contains("from: \"1.2.0\""))
    }

    @Test("Adds a portable workspace-relative path dependency")
    func addsPathDependencyToManifest() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let dependency = workspace.appendingPathComponent("Dependencies/LocalKit")
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "LocalKit")
        """.write(
            to: dependency.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "App")
        """.write(
            to: workspace.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let tool = SwiftPackageManagerTool(workspaceRoot: workspace.path, reportsChanges: false)

        let result = try await tool.call(arguments: SwiftPackageManagerArguments(
            action: "addDependency",
            dependency: "Dependencies/LocalKit",
            dependencyType: "path"
        ))

        let manifest = try String(
            contentsOf: workspace.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(result.hasPrefix("Applied 1 file change(s)"), Comment(rawValue: result))
        #expect(manifest.contains("path: \"Dependencies/LocalKit\""))
        #expect(!manifest.contains(workspace.path))
    }

    @Test("Builds and tests a package without granting source writes", .timeLimit(.minutes(1)))
    func buildsAndTestsPackage() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sources = workspace.appendingPathComponent("Sources/App", isDirectory: true)
        let tests = workspace.appendingPathComponent("Tests/AppTests", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            targets: [
                .target(name: "App"),
                .testTarget(name: "AppTests", dependencies: ["App"])
            ]
        )
        """.write(
            to: workspace.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "public func answer() -> Int { 42 }\n".write(
            to: sources.appendingPathComponent("App.swift"),
            atomically: true,
            encoding: .utf8
        )
        try """
        import XCTest
        @testable import App
        final class AppTests: XCTestCase {
            func testAnswerIsStable() {
                XCTAssertEqual(answer(), 42)
            }
        }
        """.write(
            to: tests.appendingPathComponent("AppTests.swift"),
            atomically: true,
            encoding: .utf8
        )
        let sourceBefore = try String(
            contentsOf: sources.appendingPathComponent("App.swift"),
            encoding: .utf8
        )
        let tool = SwiftPackageManagerTool(workspaceRoot: workspace.path, reportsChanges: false)

        let build = try await tool.call(arguments: SwiftPackageManagerArguments(
            action: "build",
            timeoutSeconds: 50
        ))
        let test = try await tool.call(arguments: SwiftPackageManagerArguments(
            action: "test",
            timeoutSeconds: 50
        ))

        #expect(build.contains("Exit code: 0"), Comment(rawValue: build))
        #expect(test.contains("Exit code: 0"), Comment(rawValue: test))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".build").path))
        #expect(
            try String(
                contentsOf: sources.appendingPathComponent("App.swift"),
                encoding: .utf8
            ) == sourceBefore
        )
    }

    @Test("Resolves a source-control dependency and writes Package.resolved", .timeLimit(.minutes(1)))
    func resolvesDependencyWithBoundedStateWrites() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let dependency = workspace.appendingPathComponent("Fixtures/ExampleKit", isDirectory: true)
        let dependencySources = dependency.appendingPathComponent(
            "Sources/ExampleKit",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: dependencySources,
            withIntermediateDirectories: true
        )
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "ExampleKit",
            products: [.library(name: "ExampleKit", targets: ["ExampleKit"])],
            targets: [.target(name: "ExampleKit")]
        )
        """.write(
            to: dependency.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "public let exampleValue = 1\n".write(
            to: dependencySources.appendingPathComponent("ExampleKit.swift"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["init"], in: dependency)
        try runGit(["add", "."], in: dependency)
        try runGit(
            [
                "-c", "user.name=TurboCode Tests",
                "-c", "user.email=tests@turbocode.local",
                "commit", "-m", "Initial fixture"
            ],
            in: dependency
        )
        try runGit(["tag", "1.0.0"], in: dependency)

        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "App",
            dependencies: [
                .package(url: "\(dependency.absoluteString)", exact: "1.0.0")
            ]
        )
        """.write(
            to: workspace.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let tool = SwiftPackageManagerTool(
            workspaceRoot: workspace.path,
            executionPolicy: ExecutionPolicy(allowNetworkAccess: false),
            reportsChanges: false
        )

        let result = try await tool.call(arguments: SwiftPackageManagerArguments(
            action: "resolve",
            timeoutSeconds: 50
        ))

        #expect(result.contains("Exit code: 0"), Comment(rawValue: result))
        #expect(
            FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("Package.resolved").path
            )
        )
    }

    @Test("Timed out package commands return without blocking", .timeLimit(.minutes(1)))
    func timedOutCommandReturnsControl() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sources = workspace.appendingPathComponent("Sources/Sleeper", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Sleeper",
            targets: [.executableTarget(name: "Sleeper")]
        )
        """.write(
            to: workspace.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try """
        import Foundation
        Thread.sleep(forTimeInterval: 10)
        """.write(
            to: sources.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
        let tool = SwiftPackageManagerTool(workspaceRoot: workspace.path, reportsChanges: false)
        let build = try await tool.call(arguments: SwiftPackageManagerArguments(
            action: "build",
            timeoutSeconds: 50
        ))
        #expect(build.contains("Exit code: 0"), Comment(rawValue: build))

        let startedAt = Date()
        let result = try await tool.call(arguments: SwiftPackageManagerArguments(
            action: "run",
            product: "Sleeper",
            timeoutSeconds: 1
        ))
        let duration = Date().timeIntervalSince(startedAt)

        #expect(result.contains("Command timed out or was cancelled."), Comment(rawValue: result))
        #expect(duration < 5, "The timed-out process should never strand the agent loop.")
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-SwiftPackageManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func containsSwiftSource(in directory: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        return enumerator.compactMap { $0 as? URL }.contains { $0.pathExtension == "swift" }
    }

    /// Creates a deterministic local source-control dependency without relying
    /// on network availability or the developer's global Git configuration.
    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
