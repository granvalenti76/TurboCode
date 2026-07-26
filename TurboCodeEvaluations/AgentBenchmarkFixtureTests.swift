import Foundation
import Testing
@testable import TurboCode

@Suite("Agent benchmark fixtures", .serialized)
struct AgentBenchmarkFixtureTests {
    @Test("SwiftPM fixture preserves the benchmark edit contract")
    func swiftPackageFixtureIsBuildableInput() throws {
        let workspace = try AgentBenchmarkFixture.make(.swiftPackage)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sample = try String(
            contentsOf: workspace.appendingPathComponent("Sample.md"),
            encoding: .utf8
        )
        #expect(sample == "# Notes\n\nPlaceholder")
        #expect(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("Package.swift").path
        ))
    }

    @Test("Xcode fixture is discoverable and builds through the product service")
    func xcodeFixtureInspectsAndBuilds() async throws {
        let workspace = try AgentBenchmarkFixture.make(.xcodeProject)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let service = XcodeProjectService(
            workspaceRoot: workspace.path,
            executionPolicy: ExecutionPolicy(
                maximumCommandTimeoutSeconds: 120,
                allowNetworkAccess: false
            ),
            enhancedOutput: false
        )

        let inspection = try await service.response(
            action: "inspect",
            containerPath: nil,
            scheme: nil,
            configuration: nil,
            destination: nil,
            timeoutSeconds: 45
        )
        #expect(inspection.contains("container: Benchmark.xcodeproj"))
        #expect(inspection.contains("schemes: Benchmark"))

        // Building through the same compact service used by the model proves
        // discovery, scheme selection, xcresult handling, and Swift compilation.
        let build = try await service.response(
            action: "build",
            containerPath: "Benchmark.xcodeproj",
            scheme: "Benchmark",
            configuration: "Debug",
            destination: "platform=macOS",
            timeoutSeconds: 120
        )
        #expect(build.contains("XCODE BUILD SUCCEEDED"))
    }
}
