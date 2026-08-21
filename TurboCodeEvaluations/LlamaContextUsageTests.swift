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
}
