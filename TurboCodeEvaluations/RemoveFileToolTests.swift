import Foundation
import Testing
@testable import TurboCode

@Suite("Remove file tool")
struct RemoveFileToolTests {
    @Test("Deletes only after approval and returns the final result")
    func deletesApprovedFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("Old.swift")
        try "let old = true\n".write(to: file, atomically: true, encoding: .utf8)
        let tool = RemoveFileTool(
            workspaceRoot: workspace.path,
            requestApproval: { request in
                await request.action()
            }
        )

        let result = try await tool.call(arguments: RemoveFileArguments(path: "Old.swift"))

        #expect(result == "Removed Old.swift.")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!result.contains("TURBOCODE_APPROVAL_REQUIRED"))
    }

    @Test("Keeps the file when approval is denied")
    func keepsRejectedFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("Keep.swift")
        try "let keep = true\n".write(to: file, atomically: true, encoding: .utf8)
        let tool = RemoveFileTool(
            workspaceRoot: workspace.path,
            requestApproval: { _ in "Action cancelled by the user." }
        )

        let result = try await tool.call(arguments: RemoveFileArguments(path: "Keep.swift"))

        #expect(result == "Action cancelled by the user.")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Rejects directories")
    func rejectsDirectory() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let directory = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tool = RemoveFileTool(
            workspaceRoot: workspace.path,
            requestApproval: { _ in "Unexpected approval" }
        )

        let result = try await tool.call(arguments: RemoveFileArguments(path: "Sources"))

        #expect(result == "Error: remove_file can remove files only, not directories.")
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Rejects paths outside the workspace and symbolic links")
    func rejectsUnsafePaths() async throws {
        let container = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = container.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let outside = container.appendingPathComponent("outside.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let link = workspace.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let tool = RemoveFileTool(
            workspaceRoot: workspace.path,
            requestApproval: { _ in "Unexpected approval" }
        )

        let outsideResult = try await tool.call(
            arguments: RemoveFileArguments(path: "../outside.txt")
        )
        let linkResult = try await tool.call(arguments: RemoveFileArguments(path: "link.txt"))

        #expect(outsideResult.contains("outside the workspace"))
        #expect(linkResult.contains("outside the workspace") || linkResult.contains("symbolic links"))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-RemoveFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
