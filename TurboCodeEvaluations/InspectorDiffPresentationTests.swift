import Testing
@testable import TurboCode

@Suite("Inspector diff presentation")
struct InspectorDiffPresentationTests {
    @Test("Focused context can reveal one omitted region without expanding the file")
    func revealsOneOmittedRegion() throws {
        let lines = (0..<10).map { index in
            DiffLine(
                oldLineNumber: index + 1,
                newLineNumber: index + 1,
                content: "line \(index + 1)",
                type: index == 5 ? .added : .context
            )
        }

        let focused = InspectorDiffRowBuilder.focusedRows(
            lines,
            contextRadius: 1
        )
        #expect(focused.count == 5)
        guard case .omitted(let leadingRange) = focused[0].content else {
            Issue.record("Expected leading omitted context")
            return
        }
        #expect(leadingRange == 0...3)
        guard case .omitted(let trailingRange) = focused[4].content else {
            Issue.record("Expected trailing omitted context")
            return
        }
        #expect(trailingRange == 7...9)

        let revealed = InspectorDiffRowBuilder.focusedRows(
            lines,
            contextRadius: 1,
            revealedIndices: Set(leadingRange)
        )
        #expect(revealed.count == 8)
        guard case .line = revealed[0].content else {
            Issue.record("The selected context region should be visible")
            return
        }
        guard case .omitted(let remainingRange) = revealed[7].content else {
            Issue.record("Unselected context should remain collapsed")
            return
        }
        #expect(remainingRange == trailingRange)
    }
}
