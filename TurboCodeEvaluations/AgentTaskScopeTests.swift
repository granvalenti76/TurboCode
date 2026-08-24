import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Agent task scope")
struct AgentTaskScopeTests {
    @Test("Read and search tools reject paths outside delegated scope")
    func readAndSearchRejectOutsideScope() async throws {
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
        let rejectedRead = try await read.call(
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
        #expect(rejectedRead.contains("outside the delegated task scope"))
        #expect(rejectedSearch.contains("outside the delegated task scope"))
    }

    @Test("Edit tool rejects before creating an out-of-scope file")
    func editRejectsBeforeMutation() async throws {
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

        #expect(output.contains("outside the delegated task scope"))
        #expect(
            !FileManager.default.fileExists(
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

    @Test("Filesystem and listing tools reject paths outside delegated scope")
    func filesystemAndListingRejectOutsideScope() async throws {
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

        #expect(fileResult.contains("outside the delegated task scope"))
        #expect(listingResult.errorMessage?.contains("outside the delegated task scope") == true)
    }

    @Test("Filesystem mutations cannot target the workspace root")
    func filesystemMutationsRejectWorkspaceRoot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let approval = FileSystemApprovalProbe()
        let tool = FileSystemTool(
            workspaceRoot: fixture.root.path,
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

    @Test("Workspace-wide execution tools refuse narrow delegated scopes")
    func workspaceWideToolsRefuseNarrowScope() async throws {
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

        #expect(bashResult.contains("entire-workspace task scope"))
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
