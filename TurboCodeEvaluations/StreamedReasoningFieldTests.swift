import FoundationModelsUtilities
import Testing

/// OpenAI-compatible servers disagree on where streamed thinking lives:
/// llama-server and DeepSeek use `reasoning_content`, mlx_lm.server uses
/// `reasoning`. Both must reach the reasoning channel, exactly once.
@Suite("Streamed reasoning field")
struct StreamedReasoningFieldTests {
    private typealias Executor = ChatCompletionsLanguageModel.Executor

    private func line(delta: String) -> String {
        #"data: {"id":"c1","model":"m","choices":[{"index":0,"delta":"# + delta + "}]}"
    }

    @Test("llama-server reasoning_content is read")
    func reasoningContentIsRead() throws {
        let text = try Executor.streamedReasoning(inLine: line(delta: #"{"reasoning_content":"plan"}"#))
        #expect(text == "plan")
    }

    @Test("mlx_lm reasoning is read")
    func mlxReasoningIsRead() throws {
        let text = try Executor.streamedReasoning(inLine: line(delta: #"{"role":"assistant","content":"","reasoning":"plan"}"#))
        #expect(text == "plan")
    }

    @Test("A server mirroring both fields is not doubled")
    func mirroredFieldsAreNotDoubled() throws {
        let text = try Executor.streamedReasoning(
            inLine: line(delta: #"{"reasoning_content":"plan","reasoning":"plan"}"#)
        )
        #expect(text == "plan")
    }

    @Test("A non-string reasoning value does not break the chunk")
    func objectReasoningIsIgnored() throws {
        let text = try Executor.streamedReasoning(inLine: line(delta: #"{"content":"hi","reasoning":{"summary":"x"}}"#))
        #expect(text == nil)
    }
}
