import Testing
@testable import TurboCode

@Suite("Conversation title generator")
struct ConversationTitleGeneratorTests {
    @Test("Title normalization stays bounded and optional")
    func normalizationIsDeterministic() {
        #expect(
            FoundationModelsConversationTitleGenerator.normalizedTitle(
                "  \"Fix the sidebar\"  "
            ) == "Fix the sidebar"
        )
        #expect(
            FoundationModelsConversationTitleGenerator.normalizedTitle("   \n")
                == nil
        )
        #expect(
            FoundationModelsConversationTitleGenerator.normalizedTitle(
                String(repeating: "x", count: 80)
            )?.count == 60
        )
    }
}
