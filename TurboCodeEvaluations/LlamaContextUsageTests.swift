import Testing
@testable import TurboCode

@Suite("Llama context usage")
struct LlamaContextUsageTests {
    @Test("Classifies runtime occupancy into the three UI levels")
    func classifiesOccupancy() {
        #expect(LlamaContextUsage(usedTokens: 5_999, contextSize: 10_000).level == .low)
        #expect(LlamaContextUsage(usedTokens: 6_000, contextSize: 10_000).level == .medium)
        #expect(LlamaContextUsage(usedTokens: 7_999, contextSize: 10_000).level == .medium)
        #expect(LlamaContextUsage(usedTokens: 8_000, contextSize: 10_000).level == .high)
    }

    @Test("The compact helper contains only percentage and used/total context")
    func formatsCompactTooltip() {
        let usage = LlamaContextUsage(usedTokens: 6_000, contextSize: 10_000)

        #expect(usage.tooltipText == "60% (6000/10000)")
        #expect(usage.accessibilityText == "60 percent, 6000 of 10000 tokens")
    }

    @Test("Invalid runtime measurements are clamped before presentation")
    func clampsRuntimeMeasurements() {
        let usage = LlamaContextUsage(usedTokens: -4, contextSize: 0)
        #expect(usage.usedTokens == 0)
        #expect(usage.contextSize == 1)
        #expect(usage.fraction == 0)
        #expect(usage.tooltipText == "0% (0/1)")

        let full = LlamaContextUsage(usedTokens: 20_000, contextSize: 10_000)
        #expect(full.fraction == 1)
        #expect(full.percentage == 100)
    }
}
