import Foundation
import Testing
@testable import TurboCode

@Suite("Write on-device tool")
struct WriteOnDeviceToolTests {
    @Test("Creates a UTF-8 file in the workspace root")
    func createsRootFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tool = WriteOnDeviceTool(workspaceRoot: workspace.path, reportsChanges: false)

        let result = try await tool.call(
            arguments: WriteOnDeviceArguments(fileName: "NOTES.md", content: "First draft\n")
        )

        #expect(result == "WRITE_COMPLETE: NOTES.md")
        #expect(try String(contentsOf: workspace.appendingPathComponent("NOTES.md"), encoding: .utf8) == "First draft\n")
    }

    @Test("Replaces an existing root file through the atomic edit path")
    func replacesRootFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("NOTES.md")
        try "Old\n".write(to: file, atomically: true, encoding: .utf8)
        let tool = WriteOnDeviceTool(workspaceRoot: workspace.path, reportsChanges: false)

        let result = try await tool.call(
            arguments: WriteOnDeviceArguments(fileName: "NOTES.md", content: "New\n")
        )

        #expect(result == "WRITE_COMPLETE: NOTES.md")
        #expect(try String(contentsOf: file, encoding: .utf8) == "New\n")
    }

    @Test("Rejects nested, traversal, and absolute paths", arguments: [
        "Docs/NOTES.md",
        "../NOTES.md",
        "/tmp/NOTES.md",
        "Docs\\NOTES.md"
    ])
    func rejectsNonRootPath(fileName: String) async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tool = WriteOnDeviceTool(workspaceRoot: workspace.path, reportsChanges: false)

        let result = try await tool.call(
            arguments: WriteOnDeviceArguments(fileName: fileName, content: "Blocked")
        )

        #expect(result.hasPrefix("Error: fileName must be one file name"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.path).isEmpty)
    }

    @Test("Writes Swift output beyond the former microtask envelope")
    func writesOversizedSwiftSnippet() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let tool = WriteOnDeviceTool(
            workspaceRoot: workspace.path,
            reportsChanges: false
        )
        let content = (1...31)
            .map { "let value\($0) = \($0)" }
            .joined(separator: "\n")

        let result = try await tool.call(
            arguments: WriteOnDeviceArguments(
                fileName: "Snippet.swift",
                content: content
            )
        )

        #expect(result == "WRITE_COMPLETE: Snippet.swift")
        #expect(
            try String(
                contentsOf: workspace.appendingPathComponent("Snippet.swift"),
                encoding: .utf8
            ) == content
        )
    }

    @Test("Stops repetitive empty Markdown without rejecting useful code")
    func detectsDegenerateStreamingOutput() {
        let repeatedFences = String(repeating: "```swift\n```\n\n", count: 14)
        let usefulCode = String(repeating: "```swift\nlet value = 42\n```\n", count: 6)

        #expect(OnDeviceStreamingGuard.isPathological(repeatedFences))
        #expect(!OnDeviceStreamingGuard.isPathological(usefulCode))
        #expect(!OnDeviceStreamingGuard.isPathological("```swift\n```"))
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-WriteOnDeviceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
