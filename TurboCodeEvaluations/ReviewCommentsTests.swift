import Foundation
import Testing
@testable import TurboCode

@Suite("Inline review comments")
struct ReviewCommentsTests {
    @Test("Swift highlighting preserves multiline lexical state and diff sides")
    func swiftHighlightingIsStatefulAndSideAware() throws {
        let lines = [
            "let raw = #\"not // a comment\"#",
            "/* outer",
            "   /* nested */",
            "end */ let ready = true",
            "\"\"\"",
            "multiline value",
            "\"\"\""
        ]
        let tokens = InspectorSyntaxHighlighter.swiftTokens(for: lines)

        #expect(tokens[0].contains { $0.text == "let" && $0.kind == .keyword })
        #expect(tokens[0].contains { $0.text.contains("not // a comment") && $0.kind == .string })
        #expect(tokens[1].allSatisfy { $0.kind == .comment })
        #expect(tokens[2].allSatisfy { $0.kind == .comment })
        #expect(tokens[3].contains { $0.text == "let" && $0.kind == .keyword })
        #expect(tokens[5].allSatisfy { $0.kind == .string })

        let removed = DiffLine(
            oldLineNumber: 1,
            newLineNumber: nil,
            content: "/*",
            type: .removed
        )
        let added = DiffLine(
            oldLineNumber: nil,
            newLineNumber: 1,
            content: "let current = 1",
            type: .added
        )
        let diffTokens = InspectorSyntaxHighlighter.tokens(
            for: [removed, added],
            filePath: "Sources/Example.swift"
        )
        #expect(diffTokens[added.id]?.contains {
            $0.text == "let" && $0.kind == .keyword
        } == true)
        #expect(InspectorFilePresentation.symbolName(for: "Example.swift") == "swift")
        #expect(InspectorFilePresentation.symbolName(for: "README.md") == "doc.text")
    }

    @Test("A shifted line is reanchored using its surrounding context")
    func shiftedLineReanchors() throws {
        let original = [
            diffLine(1, "alpha", .context),
            diffLine(2, "target", .added),
            diffLine(3, "omega", .context)
        ]
        let anchor = try #require(
            ReviewLineAnchor.make(
                filePath: "Sources/Feature.swift",
                lineIndex: 1,
                lines: original
            )
        )
        let shifted = [
            diffLine(1, "inserted", .added),
            diffLine(2, "alpha", .context),
            diffLine(3, "target", .added),
            diffLine(4, "omega", .context)
        ]
        let section = FileDiffSection(
            path: "Sources/Feature.swift",
            added: 2,
            removed: 0,
            diffLines: shifted
        )

        let resolved = try #require(ReviewAnchorResolver.resolve(anchor, in: [section]))
        #expect(resolved.lineNumber == 3)
        #expect(resolved.content == "target")
    }

    @Test("Ambiguous duplicate lines are never reanchored by guesswork")
    func ambiguousLineBecomesOutdated() throws {
        let original = [
            diffLine(4, "before", .context),
            diffLine(5, "duplicate", .added),
            diffLine(6, "after", .context)
        ]
        let anchor = try #require(
            ReviewLineAnchor.make(
                filePath: "Sources/Ambiguous.swift",
                lineIndex: 1,
                lines: original
            )
        )
        let ambiguous = [
            diffLine(3, "other-a", .context),
            diffLine(4, "duplicate", .added),
            diffLine(5, "middle", .context),
            diffLine(6, "duplicate", .added),
            diffLine(7, "other-b", .context)
        ]
        let section = FileDiffSection(
            path: "Sources/Ambiguous.swift",
            added: 2,
            removed: 0,
            diffLines: ambiguous
        )

        #expect(ReviewAnchorResolver.resolve(anchor, in: [section]) == nil)
    }

    @MainActor
    @Test("Draft comments survive refresh, update in place, and clear across workspaces")
    func draftLifecycleIsScopedAndReconciled() throws {
        let store = ReviewDraftStore()
        store.begin(workspaceRoot: "/tmp/one")
        let originalLines = [
            diffLine(1, "before", .context),
            diffLine(2, "target", .added),
            diffLine(3, "after", .context)
        ]
        let anchor = try #require(
            ReviewLineAnchor.make(
                filePath: "Feature.swift",
                lineIndex: 1,
                lines: originalLines
            )
        )
        let created = try #require(store.upsert(id: nil, anchor: anchor, body: "Rename this."))
        _ = store.upsert(id: created.id, anchor: anchor, body: "Use a clearer name.")

        let shiftedLines = [
            diffLine(1, "inserted", .added),
            diffLine(2, "before", .context),
            diffLine(3, "target", .added),
            diffLine(4, "after", .context)
        ]
        store.reconcile(
            workspaceRoot: "/tmp/one",
            sections: [
                FileDiffSection(
                    path: "Feature.swift",
                    added: 2,
                    removed: 0,
                    diffLines: shiftedLines
                )
            ]
        )

        #expect(store.comments.count == 1)
        #expect(store.comments[0].body == "Use a clearer name.")
        #expect(store.comments[0].anchor.lineNumber == 3)
        #expect(store.canSend)

        store.begin(workspaceRoot: "/tmp/two")
        #expect(store.comments.isEmpty)
    }

    @Test("Review requests aggregate current and removed lines compactly")
    func reviewRequestIsDeterministicAndCompact() throws {
        let currentAnchor = try #require(
            ReviewLineAnchor.make(
                filePath: "Sources/App.swift",
                lineIndex: 0,
                lines: [diffLine(12, "let title = oldTitle", .added)]
            )
        )
        let removedLine = DiffLine(
            oldLineNumber: 7,
            newLineNumber: nil,
            content: "retry()",
            type: .removed
        )
        let originalAnchor = try #require(
            ReviewLineAnchor.make(
                filePath: "Sources/Client.swift",
                lineIndex: 0,
                lines: [removedLine]
            )
        )
        let request = try #require(
            ReviewRequestBuilder.make(
                comments: [
                    ReviewComment(anchor: originalAnchor, body: "Keep the retry behavior."),
                    ReviewComment(anchor: currentAnchor, body: "Use the new title source.")
                ]
            )
        )

        #expect(request.displayText.contains("Apply 2 review comments"))
        #expect(request.promptText.contains("Sources/App.swift — current line 12"))
        #expect(request.promptText.contains("Sources/Client.swift — removed/original line 7"))
        #expect(request.promptText.contains("Keep the retry behavior."))
    }

    private func diffLine(
        _ newLineNumber: Int,
        _ content: String,
        _ type: DiffLineType
    ) -> DiffLine {
        DiffLine(
            oldLineNumber: type == .added ? nil : newLineNumber,
            newLineNumber: type == .removed ? nil : newLineNumber,
            content: content,
            type: type
        )
    }
}
