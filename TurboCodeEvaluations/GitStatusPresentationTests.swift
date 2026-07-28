import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Git status presentation")
struct GitStatusPresentationTests {
    @Test("Most modified files are ranked, tie-broken, and limited")
    func mostModifiedFilesAreDeterministic() {
        let status = makeStatus(files: [
            change("Sources/Z.swift", additions: 5, deletions: 5),
            change("Sources/A.swift", additions: 8, deletions: 2),
            change("Sources/Large.swift", additions: 20, deletions: 1),
            change("Sources/Small.swift", additions: 1, deletions: 0),
            change("Sources/Medium.swift", additions: 7, deletions: 0),
            change("Assets/Binary.dat", additions: 0, deletions: 0)
        ])

        let files = status.mostModifiedFiles(limit: 3)

        #expect(files.map(\.path) == [
            "Sources/Large.swift",
            "Sources/A.swift",
            "Sources/Z.swift"
        ])
    }

    @Test("Nonpositive limits and files without line statistics are omitted")
    func chartSelectionRequiresMeaningfulLineCounts() {
        let status = makeStatus(files: [
            change("Assets/One.dat", additions: 0, deletions: 0),
            change("Assets/Two.dat", additions: 0, deletions: 0)
        ])

        #expect(status.mostModifiedFiles().isEmpty)
        #expect(status.mostModifiedFiles(limit: 0).isEmpty)
    }

    @Test("Persisted blocks retain immutable Git status snapshots")
    func storedBlockRoundTripRetainsStatus() throws {
        let status = makeStatus(files: [
            change("Sources/App.swift", additions: 12, deletions: 3)
        ])
        let stored = StoredBlock(
            kind: ChatBlockKind.gitStatus.rawValue,
            text: "",
            gitStatus: status
        )

        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredBlock.self, from: data)

        #expect(decoded.gitStatus == status)
    }

    @Test("Status receipt is placed before the active assistant response")
    func timelinePreservesToolCallOrdering() {
        let timeline = ChatTimelineStore()
        timeline.beginResponse(
            displayText: nil,
            placeholderID: "assistant",
            model: "test-model"
        )

        timeline.presentGitStatus(makeStatus(files: [
            change("Sources/App.swift", additions: 2, deletions: 1)
        ]))

        #expect(timeline.blocks.map(\.kind) == [.gitStatus, .assistant])
    }

    /// Fixed timestamps keep equality assertions focused on the snapshot data
    /// rather than wall-clock timing.
    private func makeStatus(files: [GitStatusFileChange]) -> GitStatusBlock {
        GitStatusBlock(
            workspaceRoot: "/tmp/project",
            branch: "feature/chart",
            files: files,
            changedFilesCount: files.count,
            isClean: files.isEmpty,
            capturedAt: Date(timeIntervalSince1970: 1_000),
            errorMessage: nil
        )
    }

    private func change(
        _ path: String,
        additions: Int,
        deletions: Int
    ) -> GitStatusFileChange {
        GitStatusFileChange(
            path: path,
            additions: additions,
            deletions: deletions
        )
    }
}
