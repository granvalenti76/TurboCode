import Foundation
import Testing
@testable import FoundationModelsUtilities

@Suite("Chat-completions cache stability")
struct ChatCompletionsCacheTests {
    @Test("Request encoding sorts nested JSON keys")
    func requestEncodingIsCanonical() throws {
        let payload = Payload(
            tools: [
                "zeta": ["second": 2, "first": 1],
                "alpha": ["delta": 4, "beta": 2],
            ],
            model: "llama"
        )

        let data = try ChatCompletionsRequestEncoding.encode(payload)
        let rendered = try #require(String(data: data, encoding: .utf8))

        // JSON objects are unordered semantically, but deterministic bytes are
        // required because llama.cpp keys reuse from the tokenized prefix.
        #expect(
            rendered
                == #"{"model":"llama","tools":{"alpha":{"beta":2,"delta":4},"zeta":{"first":1,"second":2}}}"#
        )
    }

    private struct Payload: Encodable {
        let tools: [String: [String: Int]]
        let model: String
    }
}
