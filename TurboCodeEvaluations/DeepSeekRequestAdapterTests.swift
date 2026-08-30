import Foundation
import Testing
@testable import TurboCode

@Suite("DeepSeek request adapter")
struct DeepSeekRequestAdapterTests {
    @Test("Thinking response fragments are replayed as one assistant message")
    func thinkingFragmentsAreMergedWithToolCalls() throws {
        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "System"],
                ["role": "user", "content": "Inspect the project"],
                ["role": "assistant", "content": "I will inspect it."],
                ["role": "assistant", "reasoning_content": "Need the map."],
                [
                    "role": "assistant",
                    "tool_calls": [Self.toolCall(id: "call-1", name: "workspace_map")]
                ],
                ["role": "tool", "tool_call_id": "call-1", "content": "Map"]
            ]
        ]

        DeepSeekRequestAdapter.normalizeThinkingToolMessages(in: &body)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 4)
        let assistant = messages[2]
        #expect(assistant["role"] as? String == "assistant")
        #expect(assistant["content"] as? String == "I will inspect it.")
        #expect(assistant["reasoning_content"] as? String == "Need the map.")
        #expect((assistant["tool_calls"] as? [[String: Any]])?.count == 1)
        #expect(messages[3]["role"] as? String == "tool")
        #expect(messages[3]["tool_call_id"] as? String == "call-1")
    }

    @Test("Normalization is stable when replayed again")
    func normalizationIsIdempotent() throws {
        var body: [String: Any] = [
            "messages": [
                ["role": "user", "content": "Read a file"],
                ["role": "assistant", "reasoning_content": "Select the file."],
                [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [Self.toolCall(id: "call-1", name: "read_file")]
                ],
                ["role": "tool", "tool_call_id": "call-1", "content": "Contents"]
            ]
        ]

        DeepSeekRequestAdapter.normalizeThinkingToolMessages(in: &body)
        let first = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        DeepSeekRequestAdapter.normalizeThinkingToolMessages(in: &body)
        let second = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        #expect(first == second)
    }

    @Test("Assistant fragments are not merged across a user boundary")
    func userBoundaryStopsFragmentMerging() throws {
        var body: [String: Any] = [
            "messages": [
                ["role": "assistant", "content": "Previous answer"],
                ["role": "user", "content": "Next request"],
                ["role": "assistant", "reasoning_content": "Need a tool."],
                [
                    "role": "assistant",
                    "tool_calls": [Self.toolCall(id: "call-2", name: "git")]
                ],
                ["role": "tool", "tool_call_id": "call-2", "content": "Clean"]
            ]
        ]

        DeepSeekRequestAdapter.normalizeThinkingToolMessages(in: &body)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 4)
        #expect(messages[0]["content"] as? String == "Previous answer")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[2]["reasoning_content"] as? String == "Need a tool.")
        #expect(messages[2]["content"] as? String == "")
    }

    @Test("Tool-free thinking response is replayed as one assistant message")
    func toolFreeThinkingFragmentsAreMerged() throws {
        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": "System"],
                ["role": "user", "content": "Ciao"],
                ["role": "assistant", "reasoning_content": "Reply in Italian."],
                ["role": "assistant", "content": "Ciao!"],
                ["role": "user", "content": "List the files"]
            ]
        ]

        DeepSeekRequestAdapter.normalizeThinkingToolMessages(in: &body)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 4)
        #expect(messages[2]["role"] as? String == "assistant")
        #expect(messages[2]["reasoning_content"] as? String == "Reply in Italian.")
        #expect(messages[2]["content"] as? String == "Ciao!")
        #expect(messages[3]["role"] as? String == "user")
    }

    @Test("Tool output remains a boundary for the final thinking response")
    func toolOutputStopsToolFreeFragmentMerging() throws {
        var body: [String: Any] = [
            "messages": [
                ["role": "user", "content": "Inspect the project"],
                [
                    "role": "assistant",
                    "reasoning_content": "Use the map.",
                    "content": "",
                    "tool_calls": [Self.toolCall(id: "call-1", name: "workspace_map")]
                ],
                ["role": "tool", "tool_call_id": "call-1", "content": "Map"],
                ["role": "assistant", "reasoning_content": "Summarize the map."],
                ["role": "assistant", "content": "The project is small."]
            ]
        ]

        DeepSeekRequestAdapter.normalizeThinkingToolMessages(in: &body)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 4)
        #expect((messages[1]["tool_calls"] as? [[String: Any]])?.count == 1)
        #expect(messages[2]["role"] as? String == "tool")
        #expect(messages[3]["reasoning_content"] as? String == "Summarize the map.")
        #expect(messages[3]["content"] as? String == "The project is small.")
    }

    @Test("Tool definitions use a stable cache-prefix order")
    func toolDefinitionsAreCanonicalizedWithoutReorderingMessages() throws {
        var body: [String: Any] = [
            "messages": [
                ["role": "user", "content": "First"],
                ["role": "user", "content": "Second"]
            ],
            "tools": [
                Self.toolDefinition(name: "zeta"),
                Self.toolDefinition(name: "alpha")
            ]
        ]

        DeepSeekRequestAdapter.stabilizeCachePrefix(in: &body)

        let tools = try #require(body["tools"] as? [[String: Any]])
        let names = tools.compactMap {
            ($0["function"] as? [String: Any])?["name"] as? String
        }
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(names == ["alpha", "zeta"])
        #expect(messages.compactMap { $0["content"] as? String } == ["First", "Second"])
    }

    @Test("Plugin tool names are valid for DeepSeek's OpenAI-compatible payload")
    func pluginToolNamesUseProviderSafeAliases() {
        let id = TypeScriptPluginToolID(pluginID: "hello-turbo", toolName: "hello")

        #expect(id.rawValue == "hello-turbo/hello")
        #expect(id.codexName == "plugin_hello-turbo_hello")
        #expect(id.codexName.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil)
    }

    private static func toolCall(id: String, name: String) -> [String: Any] {
        [
            "id": id,
            "type": "function",
            "function": ["name": name, "arguments": "{}"]
        ]
    }

    private static func toolDefinition(name: String) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": "Test tool",
                "parameters": ["type": "object", "properties": [:]]
            ]
        ]
    }
}
