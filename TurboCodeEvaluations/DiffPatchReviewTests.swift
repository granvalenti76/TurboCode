import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Full-file edit review")
struct DiffPatchReviewTests {
    @Test("Full review preserves context and marks replacements and additions")
    func completeInlineDiffIsBuiltFromSnapshots() {
        let lines = DiffReviewLineBuilder.lines(
            original: "one\ntwo\nthree\n",
            modified: "one\nTWO\nthree\nfour\n"
        )

        #expect(lines.map(\.text) == ["one", "two", "TWO", "three", "four"])
        #expect(lines.map(\.kind) == [.context, .removal, .addition, .context, .addition])
        #expect(lines[1].oldLineNumber == 2)
        #expect(lines[2].newLineNumber == 2)
        #expect(lines[3].oldLineNumber == 3)
        #expect(lines[3].newLineNumber == 3)
    }

    @Test("Structured edits capture immutable before and after file text")
    func editPreparationCapturesFullFileSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-DiffReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = "first\nsecond\nthird\n"
        let fileURL = root.appendingPathComponent("Notes.txt")
        try original.write(to: fileURL, atomically: true, encoding: .utf8)
        let arguments = ApplyEditsArguments(files: [
            FileEditRequest(
                filePath: "Notes.txt",
                revision: FileRevision.hash(original),
                operations: [
                    LineEditOperation(
                        operation: "replace_lines",
                        startLine: 2,
                        endLine: 2,
                        content: "updated"
                    )
                ]
            )
        ])

        let prepared = try await ApplyEditsService().prepare(
            arguments: arguments,
            workspaceRoot: root.path
        )
        let snapshot = try #require(prepared.reviewFiles.first)

        #expect(snapshot.path == "Notes.txt")
        #expect(snapshot.originalText == original)
        #expect(snapshot.modifiedText == "first\nupdated\nthird\n")
        // Preparing a review is read-only; application happens in a later step.
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == original)
    }

    @Test("Repeated edits retain the first original and final modified snapshot")
    func groupedReceiptMergesReviewSnapshots() {
        let store = ChatStore(conversationRepository: DiffReviewConversationRepository())
        let file = DiffPatchFileChange(path: "TODO.md", additions: 1, deletions: 1)

        store.beginDiffPatchBlock(
            id: "group",
            patch: "first patch",
            files: [file],
            reviewFiles: [
                DiffReviewFileSnapshot(
                    path: "TODO.md",
                    originalText: "before",
                    modifiedText: "middle"
                )
            ],
            status: .applied
        )
        store.beginDiffPatchBlock(
            id: "group",
            patch: "second patch",
            files: [file],
            reviewFiles: [
                DiffReviewFileSnapshot(
                    path: "TODO.md",
                    originalText: "middle",
                    modifiedText: "after"
                )
            ],
            status: .applied
        )

        let review = store.blocks.first?.diffPatch?.reviewFiles
        #expect(review?.count == 1)
        #expect(review?.first?.originalText == "before")
        #expect(review?.first?.modifiedText == "after")
    }

    @Test("Native review presentation resolves the live receipt by stable block ID")
    func nativeReviewPresentationIsAvailableBeforeSessionRestore() {
        let store = ChatStore(conversationRepository: DiffReviewConversationRepository())
        store.beginDiffPatchBlock(
            id: "live-edit",
            patch: "patch",
            files: [DiffPatchFileChange(path: "Notes.txt", additions: 1, deletions: 0)],
            reviewFiles: [
                DiffReviewFileSnapshot(
                    path: "Notes.txt",
                    originalText: "before\n",
                    modifiedText: "after\n"
                )
            ],
            status: .applied
        )

        store.presentDiffPatchReview("live-edit")

        #expect(store.diffPatchReviewPresentation?.id == "live-edit")
        #expect(
            store.diffPatchReviewPresentation?.patch.reviewFiles?.first?.modifiedText
                == "after\n"
        )
    }

    @Test("Saved receipts without snapshots remain decodable")
    func legacyReceiptDecodesWithoutReviewSnapshots() throws {
        let data = try #require(
            """
            {
              "workspaceRoot": "/tmp/project",
              "patch": "legacy patch",
              "files": [
                { "path": "TODO.md", "additions": 1, "deletions": 0 }
              ],
              "status": "applied"
            }
            """.data(using: .utf8)
        )

        let receipt = try JSONDecoder().decode(DiffPatchBlock.self, from: data)

        // reviewFiles is deliberately optional so persisted pre-review sessions
        // continue to open and can use the existing Git-inspector fallback.
        #expect(receipt.reviewFiles == nil)
        #expect(receipt.files.map(\.path) == ["TODO.md"])
    }
}

private struct DiffReviewConversationRepository: ConversationRepository {
    func save(_ snapshot: ConversationSnapshot) throws {}
    func load(id: String) throws -> ConversationSnapshot? { nil }
    func list() throws -> [ConversationSnapshot] { [] }
    func delete(id: String) throws {}
}
