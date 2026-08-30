import Foundation
import Testing
@testable import TurboCode

@Suite("Tool receipt contracts")
struct ToolReceiptContractTests {
    @Test("Core artifact receipts retain their typed payloads")
    func artifactReceiptsRoundTrip() throws {
        let patchBlock = DiffPatchBlock(
            workspaceRoot: "/workspace",
            patch: "patch",
            patches: ["patch"],
            files: [
                DiffPatchFileChange(
                    path: "Sources/App.swift",
                    additions: 1,
                    deletions: 1
                )
            ],
            reviewFiles: nil,
            status: .applied,
            errorMessage: nil
        )
        let receipts: [ToolReceipt] = [
            .diffPatch(
                DiffPatchReceipt(
                    transactionID: "edit-1",
                    block: patchBlock
                )
            ),
            .gitStatus(
                GitStatusBlock(
                    workspaceRoot: "/workspace",
                    branch: "main",
                    files: [],
                    changedFilesCount: 0,
                    isClean: true,
                    capturedAt: Date(timeIntervalSince1970: 1),
                    errorMessage: nil
                )
            ),
            .repositoryChanged(
                RepositoryMutationReceipt(workspaceRoot: "/workspace")
            )
        ]

        let data = try JSONEncoder().encode(receipts)
        let decoded = try JSONDecoder().decode([ToolReceipt].self, from: data)

        #expect(decoded == receipts)
    }
}
