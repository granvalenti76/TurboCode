import FoundationModels
import Testing
@testable import TurboCode

@MainActor
@Suite("Foundation Models reasoning adapter")
struct FoundationModelsReasoningLevelTests {
    @Test("Provider-neutral effort maps without changing existing semantics")
    func mapsReasoningEffort() {
        #expect(FoundationModelsReasoningLevel.resolve(.low) == .light)
        #expect(FoundationModelsReasoningLevel.resolve(.medium) == .moderate)
        #expect(FoundationModelsReasoningLevel.resolve(.high) == .deep)
        #expect(FoundationModelsReasoningLevel.resolve(nil) == nil)
    }
}
