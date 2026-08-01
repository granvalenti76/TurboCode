import Foundation
import Testing
@testable import TurboCode

@Suite("Apply edits tool")
struct ApplyEditsToolTests {
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

    @Test("A stale revision is classified without overwriting the file")
    func staleRevisionDoesNotOverwrite() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode Revision \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appendingPathComponent("Counter.swift")
        try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)
        let tool = EditFileTool(
            workspaceRoot: workspace.path,
            reportsChanges: false
        )

        let result = try await tool.call(
            arguments: EditFileArguments(
                filePath: "Counter.swift",
                revision: FileRevision.hash("let value = 1\n"),
                operation: "replace_lines",
                startLine: 1,
                endLine: 1,
                content: "let value = 3"
            )
        )

        #expect(result.hasPrefix("TURBOCODE_REVISION_CONFLICT"))
        #expect(result.contains("path: Counter.swift"))
        #expect(
            try String(contentsOf: file, encoding: .utf8)
                == "let value = 2\n"
        )
    }
}
