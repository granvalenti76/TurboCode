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
}
