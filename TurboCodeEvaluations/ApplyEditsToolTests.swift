import Foundation
import Testing
@testable import TurboCode

@Suite("Apply edits tool")
struct ApplyEditsToolTests {
    @Test("Successful edits emit one terminal typed artifact without ChatStore")
    func successfulEditEmitsTypedReceipt() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode Receipt \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let registry = ToolReceiptRegistry()
        let tool = ApplyEditsTool(
            workspaceRoot: workspace.path,
            receiptRegistry: registry
        )

        let output = try await tool.call(
            arguments: ApplyEditsArguments(files: [
                FileEditRequest(
                    filePath: "Receipt.swift",
                    revision: nil,
                    operations: [
                        LineEditOperation(
                            operation: "create",
                            startLine: nil,
                            endLine: nil,
                            content: "let receipt = true\n"
                        )
                    ]
                )
            ])
        )

        let token = try #require(output.receiptToken)
        guard case .diffPatch(let artifact) = await registry.take(token) else {
            Issue.record("Expected one typed diff artifact")
            return
        }
        #expect(artifact.block.status == .applied)
        #expect(artifact.block.files.map(\.path) == ["Receipt.swift"])
        #expect(artifact.block.reviewFiles?.first?.modifiedText == "let receipt = true\n")
        #expect(await registry.take(token) == nil)
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

    @Test("An approved external edit remains atomic and reversible")
    func approvedExternalEditCanBeReversed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode External Edit \(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let externalFile = root.appendingPathComponent("External.swift")
        let original = "let value = 1\n"
        try original.write(to: externalFile, atomically: true, encoding: .utf8)
        let arguments = ApplyEditsArguments(files: [
            FileEditRequest(
                filePath: externalFile.path,
                revision: FileRevision.hash(original),
                operations: [
                    LineEditOperation(
                        operation: "replace_lines",
                        startLine: 1,
                        endLine: 1,
                        content: "let value = 2"
                    )
                ]
            )
        ])
        let tool = ApplyEditsTool(
            workspaceRoot: workspace.path,
            reportsChanges: false,
            requestApproval: { request in await request.action() }
        )

        let result = try await tool.call(arguments: arguments)

        #expect(result.hasPrefix("Applied 1 file change"))
        #expect(try String(contentsOf: externalFile, encoding: .utf8) == "let value = 2\n")

        let targets = try arguments.files.map {
            try WorkspacePathResolver.resolveForAccess($0.filePath, within: workspace.path)
        }
        let transactionRoot = WorkspacePathResolver.transactionRoot(
            workspaceRoot: workspace.path,
            targets: targets
        )
        try original.write(to: externalFile, atomically: true, encoding: .utf8)
        let prepared = try await ApplyEditsService().prepare(
            arguments: arguments,
            targets: targets,
            transactionRoot: transactionRoot
        )
        let patchService = DiffPatchService()
        try await patchService.apply(
            patch: prepared.patch,
            workspaceRoot: prepared.workspaceRoot
        )
        try await patchService.apply(
            patch: prepared.patch,
            workspaceRoot: prepared.workspaceRoot,
            reverse: true
        )
        #expect(try String(contentsOf: externalFile, encoding: .utf8) == original)
    }

    @Test("A denied external edit leaves the target unchanged")
    func deniedExternalEditDoesNotWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode Denied Edit \(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let externalFile = root.appendingPathComponent("External.swift")
        let original = "let value = 1\n"
        try original.write(to: externalFile, atomically: true, encoding: .utf8)
        let tool = EditFileTool(
            workspaceRoot: workspace.path,
            reportsChanges: false,
            requestApproval: { _ in "Action cancelled by the user." }
        )

        let result = try await tool.call(arguments: EditFileArguments(
            filePath: externalFile.path,
            revision: FileRevision.hash(original),
            operation: "replace_lines",
            startLine: 1,
            endLine: 1,
            content: "let value = 2"
        ))

        #expect(result == "Action cancelled by the user.")
        #expect(try String(contentsOf: externalFile, encoding: .utf8) == original)
    }
}
