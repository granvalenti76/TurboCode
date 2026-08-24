import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Agent task scope")
struct AgentTaskScopeTests {
    @Test("Read treats delegated paths as hints while search remains scoped")
    func readIgnoresDelegatedHintWhileSearchRemainsScoped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let scope = AgentTaskPathScope(
            workspaceRoot: fixture.root.path,
            suggestedPaths: ["Sources"]
        )
        let read = ReadFileTool(
            workspaceRoot: fixture.root.path,
            taskScope: scope
        )
        let search = RipgrepTool(
            workspaceRoot: fixture.root.path,
            taskScope: scope
        )

        let allowedRead = try await read.call(
            arguments: ReadFileArguments(
                filePath: "Sources/Allowed.swift",
                startLine: nil,
                endLine: nil,
                limit: nil
            )
        )
        let workspaceRead = try await read.call(
            arguments: ReadFileArguments(
                filePath: "Outside.swift",
                startLine: nil,
                endLine: nil,
                limit: nil
            )
        )
        let rejectedSearch = try await search.call(
            arguments: RipgrepArguments(
                action: "search",
                pattern: "outside",
                path: ".",
                filePattern: nil,
                excludePattern: nil,
                literal: nil,
                caseSensitive: nil,
                contextLines: nil,
                filesOnly: nil,
                hidden: nil,
                maxResults: nil
            )
        )

        #expect(allowedRead.contains("let allowed = true"))
        #expect(workspaceRead.contains("let outside = true"))
        #expect(rejectedSearch.contains("outside the delegated task scope"))
    }

    @Test("Edit treats delegated paths as hints")
    func editIgnoresDelegatedHint() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tool = EditFileTool(
            workspaceRoot: fixture.root.path,
            reportsChanges: false,
            taskScope: AgentTaskPathScope(
                workspaceRoot: fixture.root.path,
                suggestedPaths: ["Sources"]
            )
        )

        let output = try await tool.call(
            arguments: EditFileArguments(
                filePath: "Forbidden.swift",
                revision: nil,
                operation: "create",
                startLine: nil,
                endLine: nil,
                content: "let forbidden = true\n"
            )
        )

        #expect(output.hasPrefix("Applied 1 file change"))
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("Forbidden.swift").path
            )
        )
    }

    @Test("Empty task scope preserves workspace-wide tool behavior")
    func emptyScopePreservesWorkspaceBoundary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let scope = AgentTaskPathScope(
            workspaceRoot: fixture.root.path,
            suggestedPaths: []
        )

        #expect(throws: Never.self) {
            try scope.validate("Outside.swift")
        }
        #expect(throws: FileSystemError.self) {
            try WorkspacePathResolver.resolve("../escape", within: fixture.root.path)
        }
    }

    @Test("Filesystem treats delegated paths as hints while listing remains scoped")
    func filesystemIgnoresDelegatedHintWhileListingRemainsScoped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let scope = AgentTaskPathScope(
            workspaceRoot: fixture.root.path,
            suggestedPaths: ["Sources"]
        )
        let fileSystem = FileSystemTool(workspaceRoot: fixture.root.path, taskScope: scope)
        let listing = ListWorkspaceTool(workspaceRoot: fixture.root.path, taskScope: scope)

        let fileResult = try await fileSystem.call(
            arguments: FileSystemArguments(
                operation: "info",
                path: "Outside.swift",
                destination: nil,
                pattern: nil,
                content: nil
            )
        )
        let listingResult = try await listing.call(
            arguments: ListWorkspaceArguments(path: ".")
        )

        #expect(fileResult.contains("Outside.swift"))
        #expect(listingResult.errorMessage?.contains("outside the delegated task scope") == true)
    }

    @Test("External filesystem reads and writes continue after one approval")
    func externalFilesystemOperationsUseOneApproval() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-ExternalFilesystem-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external.txt")
        try "before\n".write(to: external, atomically: true, encoding: .utf8)
        let approval = FileSystemApprovalProbe()
        let tool = FileSystemTool(
            workspaceRoot: workspace.path,
            requestApproval: { request in await approval.handle(request) }
        )

        let info = try await tool.call(arguments: FileSystemArguments(
            operation: "info",
            path: external.path,
            destination: nil,
            pattern: nil,
            content: nil
        ))
        let write = try await tool.call(arguments: FileSystemArguments(
            operation: "write",
            path: external.path,
            destination: nil,
            pattern: nil,
            content: "after\n"
        ))

        #expect(approval.count == 2)
        #expect(info.contains("external.txt"))
        #expect(write.hasPrefix("Applied 1 file change"))
        #expect(try String(contentsOf: external, encoding: .utf8) == "after\n")
    }

    @Test("Denied external filesystem writes do not inspect or mutate the target")
    func deniedExternalFilesystemWriteDoesNotMutate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-DeniedFilesystem-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("external.txt")
        try "before\n".write(to: external, atomically: true, encoding: .utf8)
        let tool = FileSystemTool(
            workspaceRoot: workspace.path,
            requestApproval: { _ in "Action cancelled by the user." }
        )

        let result = try await tool.call(arguments: FileSystemArguments(
            operation: "write",
            path: external.path,
            destination: nil,
            pattern: nil,
            content: "after\n"
        ))

        #expect(result == "Action cancelled by the user.")
        #expect(try String(contentsOf: external, encoding: .utf8) == "before\n")
    }

    @Test("Filesystem mutations cannot target the workspace root")
    func filesystemMutationsRejectWorkspaceRoot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let approval = FileSystemApprovalProbe()
        let scope = AgentTaskPathScope(
            workspaceRoot: fixture.root.path,
            suggestedPaths: ["Sources"]
        )
        let tool = FileSystemTool(
            workspaceRoot: fixture.root.path,
            taskScope: scope,
            requestApproval: { request in
                await approval.handle(request)
            }
        )

        let createResult = try await tool.call(
            arguments: FileSystemArguments(
                operation: "createDirectory",
                path: ".",
                destination: nil,
                pattern: nil,
                content: nil
            )
        )
        let deleteResult = try await tool.call(
            arguments: FileSystemArguments(
                operation: "delete",
                path: ".",
                destination: nil,
                pattern: nil,
                content: nil
            )
        )

        #expect(createResult.contains("workspace root itself"))
        #expect(deleteResult.contains("workspace root itself"))
        #expect(approval.count == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test("Delete returns the approved result through the tool call")
    func deleteUsesSuspendingApproval() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let approval = FileSystemApprovalProbe()
        let tool = FileSystemTool(
            workspaceRoot: fixture.root.path,
            requestApproval: { request in
                await approval.handle(request)
            }
        )

        let result = try await tool.call(
            arguments: FileSystemArguments(
                operation: "delete",
                path: "Outside.swift",
                destination: nil,
                pattern: nil,
                content: nil
            )
        )

        #expect(approval.count == 1)
        #expect(result.contains("Deleted"))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Outside.swift").path))
    }

    @Test("Move requires approval and rejects a changed source")
    func moveRevalidatesBeforeExecution() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("Moved.swift")
        let approval = FileSystemApprovalProbe()
        approval.beforeAction = {
            try? "replacement with a different size\n".write(
                to: fixture.root.appendingPathComponent("Outside.swift"),
                atomically: true,
                encoding: .utf8
            )
        }
        let tool = FileSystemTool(
            workspaceRoot: fixture.root.path,
            requestApproval: { request in
                await approval.handle(request)
            }
        )

        let result = try await tool.call(
            arguments: FileSystemArguments(
                operation: "move",
                path: "Outside.swift",
                destination: "Moved.swift",
                pattern: nil,
                content: nil
            )
        )

        #expect(approval.count == 1)
        #expect(result.contains("changed before approval"))
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Outside.swift").path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("External destructive operations reject a target changed during approval")
    func externalDeleteRevalidatesBeforeExecution() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = URL(
            fileURLWithPath: "/private/tmp/TurboCode-ExternalDelete-\(UUID().uuidString).txt"
        )
        defer { try? FileManager.default.removeItem(at: external) }
        try "original\n".write(to: external, atomically: true, encoding: .utf8)
        let approval = FileSystemApprovalProbe()
        approval.beforeAction = {
            try? "replacement with a different size\n".write(
                to: external,
                atomically: true,
                encoding: .utf8
            )
        }
        let tool = FileSystemTool(
            workspaceRoot: fixture.root.path,
            requestApproval: { request in
                await approval.handle(request)
            }
        )

        let result = try await tool.call(
            arguments: FileSystemArguments(
                operation: "delete",
                path: external.path,
                destination: nil,
                pattern: nil,
                content: nil
            )
        )

        #expect(approval.count == 1)
        #expect(result.contains("changed before approval"))
        #expect(FileManager.default.fileExists(atPath: external.path))
    }

    @Test("Find reports truncation only when a 201st match exists")
    func findReportsAccurateTruncation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for index in 0..<200 {
            try "file\(index)".write(
                to: fixture.root.appendingPathComponent("Match-\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }
        let tool = FileSystemTool(workspaceRoot: fixture.root.path)
        let exactResult = try await tool.call(
            arguments: FileSystemArguments(
                operation: "find",
                path: ".",
                destination: nil,
                pattern: "*.txt",
                content: nil
            )
        )

        try "file200".write(
            to: fixture.root.appendingPathComponent("Match-200.txt"),
            atomically: true,
            encoding: .utf8
        )
        let truncatedResult = try await tool.call(
            arguments: FileSystemArguments(
                operation: "find",
                path: ".",
                destination: nil,
                pattern: "*.txt",
                content: nil
            )
        )

        #expect(exactResult.contains("Found 200 files"))
        #expect(!exactResult.contains("truncated"))
        #expect(truncatedResult.contains("Found 200 files"))
        #expect(truncatedResult.contains("truncated"))
    }

    @Test("Bash treats delegated paths as hints while structured Git remains scoped")
    func bashIgnoresDelegatedHintWhileGitRemainsScoped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let scope = AgentTaskPathScope(
            workspaceRoot: fixture.root.path,
            suggestedPaths: ["Sources"]
        )

        let bash = BashTool(workspaceRoot: fixture.root.path, taskScope: scope)
        let git = GitTool(
            workspaceRoot: fixture.root.path,
            policy: GitPolicy(),
            executionPolicy: ExecutionPolicy(),
            taskScope: scope
        )

        let bashResult = try await bash.call(arguments: BashArguments(command: "pwd"))
        let gitResult = try await git.call(
            arguments: GitArguments(operation: "status", paths: nil, branch: nil, message: nil, remote: nil, limit: nil)
        )

        #expect(bashResult.contains("Exit code: 0"))
        #expect(bashResult.contains(fixture.root.path))
        #expect(gitResult.contains("entire-workspace task scope"))
    }

    private func makeFixture() throws -> (root: URL, source: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-AgentScope-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try "let allowed = true\n".write(
            to: source.appendingPathComponent("Allowed.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "let outside = true\n".write(
            to: root.appendingPathComponent("Outside.swift"),
            atomically: true,
            encoding: .utf8
        )
        return (root, source)
    }
}

private final class FileSystemApprovalProbe: @unchecked Sendable {
    var count = 0
    var beforeAction: (() -> Void)?

    func handle(_ request: PendingToolApproval) async -> String {
        count += 1
        beforeAction?()
        return await request.action()
    }
}
