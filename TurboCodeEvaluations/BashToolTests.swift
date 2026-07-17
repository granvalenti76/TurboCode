import Foundation
import Testing
@testable import TurboCode

@Suite("Bash tool")
struct BashToolTests {
    @Test("SwiftPM builds can write artifacts without modifying sources", .timeLimit(.minutes(1)))
    func swiftPMBuildCanWriteArtifactsWithoutModifyingSources() async throws {
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

        let tool = BashTool(workspaceRoot: workspace.path)
        let output = try await tool.call(
            arguments: BashArguments(command: "swift build", timeoutSeconds: 50, maxOutputCharacters: 12_000)
        )

        #expect(output.contains("Exit code: 0"))
        #expect(!output.contains("not accessible or not writable"))
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".build").path))

        let deniedWrite = try await tool.call(
            arguments: BashArguments(
                command: "printf overwritten > Sources/App/main.swift",
                timeoutSeconds: 10,
                maxOutputCharacters: 4_000
            )
        )
        #expect(!deniedWrite.contains("Exit code: 0"))
        #expect(try String(contentsOf: sources.appendingPathComponent("main.swift"), encoding: .utf8) == "print(\"ok\")\n")
    }
}
