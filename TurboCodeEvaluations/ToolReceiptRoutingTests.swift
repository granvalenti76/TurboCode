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
}
