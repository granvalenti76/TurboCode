import FoundationModelsUtilities
import Testing

/// Streamed tool-call ids and names must survive servers that repeat the full
/// value in every delta as well as servers that split it across deltas.
@Suite("Tool-call stream merge")
struct ToolCallStreamMergeTests {
    private typealias Executor = ChatCompletionsLanguageModel.Executor

    @Test("Repeated id and name deltas are not concatenated")
    func repeatedFragmentsAreIgnored() {
        var id = ""
        var name = ""
        for _ in 0..<3 {
            id = Executor.mergeToolCallFragment(id, "call_abc")
            name = Executor.mergeToolCallFragment(name, "read_file")
        }

        #expect(id == "call_abc")
        #expect(name == "read_file")
    }

    @Test("Split fragments and missing deltas still produce the full value")
    func splitFragmentsAreJoined() {
        var name = Executor.mergeToolCallFragment("", "read_")
        name = Executor.mergeToolCallFragment(name, nil)
        name = Executor.mergeToolCallFragment(name, "file")
        name = Executor.mergeToolCallFragment(name, "")

        #expect(name == "read_file")
    }
}
