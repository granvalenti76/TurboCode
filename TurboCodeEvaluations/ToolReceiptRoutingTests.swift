import Foundation
import FoundationModels
import Testing
@testable import TurboCode

@Suite("Tool receipt adapter routing")
struct ToolReceiptRoutingTests {
    @Test("Compact output consumes its typed receipt exactly once")
    func compactOutputConsumesReceiptOnce() async {
        let registry = ToolReceiptRegistry()
        let expected = ToolReceipt.repositoryChanged(
            RepositoryMutationReceipt(workspaceRoot: "/workspace")
        )
        let token = await registry.store(expected)
        let call = Transcript.ToolCall(
            id: "mutation",
            toolName: "git",
            arguments: GeneratedContent(properties: [:])
        )
        let output = Transcript.ToolOutput(
            id: call.id,
            toolName: call.toolName,
            segments: [
                .structure(
                    Transcript.StructuredSegment(
                        schemaName: "ToolCommandOutput",
                        content: GeneratedContent(
                            ToolCommandOutput(
                                text: "Updated repository",
                                receiptToken: token
                            )
                        )
                    )
                )
            ]
        )

        let first = await ToolReceiptRouter.resolve(
            for: call,
            output: output,
            registry: registry,
            workspaceName: nil
        )
        let second = await ToolReceiptRouter.resolve(
            for: call,
            output: output,
            registry: registry,
            workspaceName: nil
        )

        #expect(first.text == "Updated repository")
        #expect(first.receipt == expected)
        #expect(second.text == first.text)
        #expect(second.receipt == nil)
        #expect(await registry.storedReceiptCount == 0)
    }

    @Test("Registry evicts the oldest abandoned receipt at capacity")
    func registryIsBounded() async {
        let registry = ToolReceiptRegistry(capacity: 1)
        let firstToken = await registry.store(
            .repositoryChanged(RepositoryMutationReceipt(workspaceRoot: "/first"))
        )
        let second = ToolReceipt.repositoryChanged(
            RepositoryMutationReceipt(workspaceRoot: "/second")
        )
        let secondToken = await registry.store(second)

        #expect(await registry.take(firstToken) == nil)
        #expect(await registry.take(secondToken) == second)
    }

    @MainActor
    @Test("Current native completion projects its correlated diff receipt")
    func nativeCompletionProjectsDiffReceipt() async {
        let registry = ToolReceiptRegistry()
        let timeline = ChatTimelineStore()
        let runtime = AgentRuntime()
        let workspace = WorkspaceStore(gitService: GitDiffService())
        let review = ReviewCoordinator(
            timeline: timeline,
            workbench: WorkbenchStore(),
            workspace: workspace,
            gitService: GitDiffService(),
            diffPatchService: DiffPatchService()
        )
        let coordinator = ChatResponseCoordinator(
            timeline: timeline,
            toolInteractions: ToolInteractionStore(),
            agentActivity: AgentActivityStore(),
            agentRuntime: runtime,
            llmRuntime: LLMRuntime(),
            receiptRegistry: registry,
            reviewCoordinator: review
        )
        let turnID = TurnID(rawValue: "native-diff-turn")
        #expect(await runtime.apply(.started(TurnRequest(
            id: turnID,
            prompt: "Edit the file",
            backend: .llamaServer,
            modelName: "fixture",
            workspaceRoot: "/workspace"
        ))))
        let block = DiffPatchBlock(
            workspaceRoot: "/workspace",
            patch: "fixture patch",
            patches: nil,
            files: [DiffPatchFileChange(path: "App.swift", additions: 1, deletions: 0)],
            reviewFiles: nil,
            status: .failed,
            errorMessage: "fixture failure"
        )
        let token = await registry.store(
            .diffPatch(DiffPatchReceipt(transactionID: "transaction", block: block))
        )
        let call = Transcript.ToolCall(
            id: "native-edit",
            toolName: "edit_file",
            arguments: GeneratedContent(properties: [:])
        )
        let output = Transcript.ToolOutput(
            id: call.id,
            toolName: call.toolName,
            segments: [
                .structure(Transcript.StructuredSegment(
                    schemaName: "ToolCommandOutput",
                    content: GeneratedContent(ToolCommandOutput(
                        text: "Applied one edit",
                        receiptToken: token
                    ))
                ))
            ]
        )

        await coordinator.toolStarted(
            call,
            backend: .llamaServer,
            owner: .coordinator
        )
        await coordinator.toolFinished(
            call,
            output: output,
            backend: .llamaServer,
            owner: .coordinator,
            workspaceName: "Fixture"
        )

        let projected = timeline.blocks.compactMap(\.diffPatch)
        #expect(projected.count == 1)
        #expect(projected.first?.status == .failed)
        #expect(projected.first?.errorMessage == "fixture failure")
        #expect(projected.first?.files.map(\.path) == ["App.swift"])
        #expect(await registry.storedReceiptCount == 0)
    }

    @Test("Git mutations and status emit host-owned receipts")
    func gitEmitsMutationAndStatusReceipts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode Git Receipt \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ToolReceiptRegistry()
        let tool = GitTool(
            workspaceRoot: root.path,
            policy: GitPolicy(),
            executionPolicy: ExecutionPolicy(),
            receiptRegistry: registry
        )

        let initialized = try await tool.call(arguments: GitArguments(
            operation: "init",
            paths: nil,
            branch: nil,
            message: nil,
            remote: nil,
            limit: nil
        ))
        let mutationToken = try #require(initialized.receiptToken)
        #expect(
            await registry.take(mutationToken)
                == .repositoryChanged(RepositoryMutationReceipt(workspaceRoot: root.path))
        )

        let status = try await tool.call(arguments: GitArguments(
            operation: "status",
            paths: nil,
            branch: nil,
            message: nil,
            remote: nil,
            limit: nil
        ))
        let statusToken = try #require(status.receiptToken)
        guard case .gitStatus(let snapshot) = await registry.take(statusToken) else {
            Issue.record("Expected a typed Git status snapshot")
            return
        }
        #expect(snapshot.workspaceRoot == root.path)
        #expect(snapshot.branch == "main")
        #expect(snapshot.isClean)
    }
}
