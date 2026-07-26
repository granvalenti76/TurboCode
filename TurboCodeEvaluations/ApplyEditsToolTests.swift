import Foundation
import Testing
@testable import TurboCode

@Suite("Apply edits tool")
struct ApplyEditsToolTests {
    @Test("Revision tokens are compact deterministic concurrency guards")
    func revisionTokensAreCompactAndDeterministic() {
        let first = FileRevision.hash("unchanged")
        let second = FileRevision.hash("unchanged")
        let changed = FileRevision.hash("changed")

        #expect(first.count == 32)
        #expect(first == second)
        #expect(first != changed)
        #expect(first.allSatisfy { $0.isHexDigit })
    }

    @Test("A stale edit reports the exact current revision")
    func staleEditReportsCurrentRevision() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode Stale Edit \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fileURL = workspace.appendingPathComponent("Sample.swift")
        let original = "let value = 1\n"
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let result = try await EditFileTool(
            workspaceRoot: workspace.path,
            reportsChanges: false
        ).call(
            arguments: EditFileArguments(
                filePath: "Sample.swift",
                revision: "stale",
                operation: "replace_lines",
                startLine: 1,
                endLine: 1,
                content: "let value = 2"
            )
        )

        #expect(result.contains(FileRevision.hash(original)))
        #expect(result.contains("copy only that value"))
        let finalContent = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(finalContent == original)
    }

    @Test("Creates a file below directories whose names contain spaces")
    func createsFileInPathContainingSpaces() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode Apply Edits \(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = workspace
            .appendingPathComponent("Untitled Project/Untitled Project", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Leave the workspace outside Git to exercise the BSD patch fallback that
        // previously truncated an unquoted path at its first space.
        let tool = ApplyEditsTool(workspaceRoot: workspace.path, reportsChanges: false)
        let result = try await tool.call(
            arguments: ApplyEditsArguments(
                files: [
                    FileEditRequest(
                        filePath: "Untitled Project/Untitled Project/ModaleUI.swift",
                        revision: nil,
                        operations: [
                            LineEditOperation(
                                operation: "create",
                                startLine: nil,
                                endLine: nil,
                                content: "import SwiftUI\n"
                            )
                        ]
                    )
                ]
            )
        )

        let expectedFile = sourceDirectory.appendingPathComponent("ModaleUI.swift")
        #expect(result.hasPrefix("Applied 1 file change"))
        #expect(try String(contentsOf: expectedFile, encoding: .utf8) == "import SwiftUI\n")
        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Untitled").path))
    }
}
