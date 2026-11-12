import Foundation
import FoundationModels
import FoundationModelsUtilities
import Testing
@testable import TurboCode

@MainActor
@Suite("Steering injection at the tool boundary", .serialized)
struct SteeringBoundaryInjectionTests {
    @Test("Claimed steering reaches the next model request after the tool output")
    func claimedSteeringFollowsTheToolOutputInTheSameTurn() async throws {
        BoundaryWireURLProtocol.reset(responses: [
            BoundaryWireURLProtocol.toolCallStream,
            BoundaryWireURLProtocol.textStream
        ])
        defer { BoundaryWireURLProtocol.reset(responses: []) }

        // The real modifier, fed by a claim that yields one instruction.
        let claims = OneShotClaim(text: "STEERED")
        let session = makeSession(claim: { await claims.take() })

        _ = try await session.respond(to: "ORIGINAL")

        let bodies = BoundaryWireURLProtocol.capturedBodies()
        #expect(bodies.count == 2)
        let messages = try #require(bodies.last?["messages"] as? [[String: Any]])

        // The steering must follow the tool result on the wire, even though
        // the hook appended it before the framework recorded that result.
        #expect(
            messages.compactMap { $0["role"] as? String }
                == ["system", "user", "assistant", "tool", "user"]
        )
        #expect(messages.last?["content"] as? String == "STEERED")
        #expect(messages[3]["tool_call_id"] as? String == "call_1")

        // The live session keeps the hook's order; durable history must not.
        let canonical = Transcript.deferringPromptsPastToolOutputs(session.transcript)
        #expect(
            canonical.map(Self.kind)
                == ["instructions", "prompt", "toolCalls", "toolOutput", "prompt", "response"]
        )
    }

    @Test("Nothing is injected when no steering is queued")
    func noClaimLeavesTheRequestUnchanged() async throws {
        let messages = try await secondRequestMessages(claim: { nil })
        #expect(
            messages.compactMap { $0["role"] as? String }
                == ["system", "user", "assistant", "tool"]
        )
    }

    @Test("A prompt waits for every output of a parallel tool-call entry")
    func promptIsDeferredPastAllParallelOutputs() {
        let calls = ["a", "b"].map {
            Transcript.ToolCall(
                id: $0,
                toolName: "echo_probe",
                arguments: GeneratedContent(properties: ["text": $0])
            )
        }
        let output: (String) -> Transcript.Entry = { id in
            .toolOutput(Transcript.ToolOutput(
                id: id,
                toolName: "echo_probe",
                segments: [.text(Transcript.TextSegment(content: id))]
            ))
        }
        let prompt = Transcript.Entry.prompt(Transcript.Prompt(segments: [
            .text(Transcript.TextSegment(content: "STEERED"))
        ]))
        let ordered = Transcript.deferringPromptsPastToolOutputs([
            .toolCalls(Transcript.ToolCalls(calls)),
            output("a"),
            prompt,
            output("b")
        ])
        #expect(ordered.map(Self.kind) == ["toolCalls", "toolOutput", "toolOutput", "prompt"])

        // An interrupted call never gets its output; the prompt must survive.
        let interrupted = Transcript.deferringPromptsPastToolOutputs([
            .toolCalls(Transcript.ToolCalls(calls)),
            prompt
        ])
        #expect(interrupted.map(Self.kind) == ["toolCalls", "prompt"])
    }

    private func secondRequestMessages(
        claim: @escaping @Sendable () async -> String?
    ) async throws -> [[String: Any]] {
        BoundaryWireURLProtocol.reset(responses: [
            BoundaryWireURLProtocol.toolCallStream,
            BoundaryWireURLProtocol.textStream
        ])
        defer { BoundaryWireURLProtocol.reset(responses: []) }
        let session = makeSession(claim: claim)
        _ = try await session.respond(to: "ORIGINAL")
        let bodies = BoundaryWireURLProtocol.capturedBodies()
        return try #require(bodies.last?["messages"] as? [[String: Any]])
    }

    private func makeSession(
        claim: @escaping @Sendable () async -> String?
    ) -> LanguageModelSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundaryWireURLProtocol.self]
        let model = ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "https://boundary.invalid")!,
            supportsGuidedGeneration: false,
            urlSessionConfiguration: configuration
        )
        return LanguageModelSession(
            profile: BoundaryProbeProfile(model: model, claim: claim),
            history: []
        )
    }

    private static func kind(_ entry: Transcript.Entry) -> String {
        switch entry {
        case .prompt: "prompt"
        case .toolCalls: "toolCalls"
        case .toolOutput: "toolOutput"
        case .response: "response"
        case .reasoning: "reasoning"
        case .instructions: "instructions"
        @unknown default: "other"
        }
    }
}

@Generable
struct BoundaryProbeArguments {
    var text: String
}

private struct BoundaryProbeTool: Tool {
    var name: String { "echo_probe" }
    var description: String { "Echo the text." }

    func call(arguments: BoundaryProbeArguments) async throws -> String {
        "echo: \(arguments.text)"
    }
}

private struct BoundaryProbeProfile: LanguageModelSession.DynamicProfile {
    let model: any LanguageModel
    let claim: @Sendable () async -> String?

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions("SYSTEM")
            BoundaryProbeTool()
        }
        .model(model)
        .modifier(SteeringBoundaryModifier(claim: claim))
    }
}

/// Stands in for the steering queue: the first boundary gets the text.
private actor OneShotClaim {
    private var text: String?

    init(text: String) {
        self.text = text
    }

    func take() -> String? {
        defer { text = nil }
        return text
    }
}

private final class BoundaryWireURLProtocol: URLProtocol, @unchecked Sendable {
    static let toolCallStream = """
    data: {"id":"r1","model":"wire-model","choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"echo_probe","arguments":"{\\"text\\":\\"hi\\"}"}}]}}]}

    data: [DONE]


    """
    static let textStream = """
    data: {"id":"r2","model":"wire-model","choices":[{"delta":{"role":"assistant","content":"done"}}]}

    data: [DONE]


    """

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String] = []
    nonisolated(unsafe) private static var bodies: [[String: Any]] = []

    static func reset(responses: [String]) {
        lock.withLock {
            self.responses = responses
            bodies = []
        }
    }

    static func capturedBodies() -> [[String: Any]] {
        lock.withLock { bodies }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "boundary.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.bodyData(from: request)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let stream = Self.lock.withLock { () -> String in
            Self.bodies.append(body)
            return Self.responses.isEmpty ? Self.textStream : Self.responses.removeFirst()
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return stream.read(base, maxLength: bytes.count)
            }
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
