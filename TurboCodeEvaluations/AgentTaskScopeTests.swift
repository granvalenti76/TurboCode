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
        let search = GrepTool(
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
            arguments: SearchArguments(
                pattern: "outside",
                path: ".",
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

    @Test("Runner maps an out-of-scope call to a typed terminal result")
    func runnerMapsScopeViolation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let envelope = try AgentTaskEnvelope(
            taskID: "scope-task",
            attemptID: "scope-attempt",
            goal: "Read only the allowed source.",
            acceptanceCriteria: ["Do not inspect unrelated files."],
            suggestedScope: ["Sources"],
            budget: DelegationBudget(timeoutSeconds: 5, maximumToolCalls: 2)
        )
        let gate = AgentTaskExecutionGate(
            allowedToolNames: ["read_file"],
            maximumToolCalls: 2,
            pathScope: AgentTaskPathScope(
                workspaceRoot: fixture.root.path,
                suggestedPaths: envelope.suggestedScope
            )
        )
        let call = Transcript.ToolCall(
            id: "scope-call",
            toolName: "read_file",
            arguments: GeneratedContent(properties: ["filePath": "Outside.swift"])
        )
        let runner = BoundedAgentTaskRunner(worker: OutOfScopeTaskWorker())

        #expect(await gate.beginTool(call) == .pathOutsideScope("Outside.swift"))
        #expect(await gate.count == 0)
        let result = await runner.run(
            envelope: envelope,
            context: AgentTaskRunContext(
                model: SystemLanguageModel.default,
                toolPlan: ModelToolPlan(
                    profile: .delegate,
                    tier: .standard,
                    assignments: [
                        .init(id: .readFile, isRegistered: true, unavailableReason: nil)
                    ]
                ),
                tools: [
                    ReadFileTool(workspaceRoot: fixture.root.path)
                ],
                workspaceRoot: fixture.root.path,
                instructions: "Stay inside task scope.",
                temperature: nil,
                reasoningLevel: nil
            ),
            events: .none
        )

        #expect(result.outcome == .failed)
        #expect(result.failureReason == .pathOutsideScope)
        #expect(result.failureDetail?.contains("Outside.swift") == true)
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

private struct OutOfScopeTaskWorker: AgentTaskWorkerExecuting {
    @MainActor
    func execute(
        envelope: AgentTaskEnvelope,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents
    ) async throws -> String {
        // FoundationModelsTaskWorker throws the gate's recorded violation after
        // cancellation. This fake isolates the runner's typed result mapping.
        throw AgentTaskWorkerError.pathOutsideScope("Outside.swift")
    }
}
