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

        #expect(result.contains("Applied 1 file change"))
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

        #expect(result.contains("Applied 1 file change"))
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

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-WriteOnDeviceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
