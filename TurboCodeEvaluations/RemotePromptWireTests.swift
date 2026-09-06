import Foundation
import FoundationModels
import FoundationModelsUtilities
import Testing
@testable import TurboCode

@MainActor
@Suite("Remote prompt wire contract", .serialized)
struct RemotePromptWireTests {
    @Test("Remote standalone request sends one neutral system message")
    func standaloneRequestPreservesCompletePrompt() async throws {
        let capture = try await captureRequest(safariEnabled: false)
        let messages = try #require(capture.body["messages"] as? [[String: Any]])

        #expect(capture.url.path == "/v1/chat/completions")
        #expect(capture.method == "POST")
        #expect(messages.compactMap { $0["role"] as? String } == ["system", "user"])
        #expect(messages[0]["content"] as? String == capture.expectedSystemPrompt)
        #expect(messages[1]["content"] as? String == Self.userPrompt)

        let systemPrompt = try #require(messages[0]["content"] as? String)
        #expect(systemPrompt.contains("Wire-level workspace instruction."))
        #expect(!systemPrompt.contains("Reasoning policy"))
        #expect(!systemPrompt.contains("Final reasoning requirement"))
        #expect(!systemPrompt.contains("Keep responses focused"))
        #expect(!systemPrompt.contains("do not repeat their contents"))
        #expect(!systemPrompt.contains("without calling tools"))
        #expect(toolNames(in: capture.body) == ["list_workspace"])
    }

    @Test("Safari adds scoped activation content to the system message")
    func safariActivationRemainsConditionalAndToolNeutral() async throws {
        let capture = try await captureRequest(safariEnabled: true)
        let messages = try #require(capture.body["messages"] as? [[String: Any]])
        let systemMessages = messages.filter { $0["role"] as? String == "system" }
        let toolNames = toolNames(in: capture.body)

        #expect(messages.compactMap { $0["role"] as? String } == ["system", "user"])
        #expect(systemMessages.count == 1)

        let systemSegments = textSegments(in: try #require(systemMessages.first))
        #expect(systemSegments.first == capture.expectedSystemPrompt)

        let completeSystemPrompt = systemSegments.joined(separator: "\n")
        #expect(completeSystemPrompt.contains(SafariMCPFeature.activationInstructions))
        #expect(completeSystemPrompt.contains("does not restrict any other available tool"))
        #expect(!completeSystemPrompt.contains("without calling tools"))
        #expect(toolNames.contains("activate_safari_skill"))
        #expect(toolNames.contains("list_workspace"))
    }

    @Test("Reasoning-only and empty assistant history keeps a valid wire envelope", arguments: [true, false])
    func incompleteAssistantHistoryHasContent(reasoningOnly: Bool) async throws {
        let entry: Transcript.Entry = reasoningOnly
            ? .reasoning(Transcript.Reasoning(segments: [
                .text(Transcript.TextSegment(content: "Pending reasoning"))
            ]))
            : .response(Transcript.Response(assetIDs: [], segments: []))
        let capture = try await captureRequest(
            safariEnabled: false,
            history: [
                .prompt(Transcript.Prompt(segments: [
                    .text(Transcript.TextSegment(content: "Previous task"))
                ])),
                entry
            ]
        )
        let messages = try #require(capture.body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        #expect(assistant["content"] as? String == "")
        if reasoningOnly {
            #expect(assistant["reasoning_content"] as? String == "Pending reasoning")
        }
    }

    @Test("Reasoning stays attached to tool calls with their matching output")
    func toolExchangePreservesWireContract() async throws {
        let call = Transcript.ToolCall(
            id: "wire-call",
            toolName: "list_workspace",
            arguments: GeneratedContent(properties: ["path": "."])
        )
        let capture = try await captureRequest(
            safariEnabled: false,
            history: [
                .prompt(Transcript.Prompt(segments: [
                    .text(Transcript.TextSegment(content: "List the workspace"))
                ])),
                .reasoning(Transcript.Reasoning(segments: [
                    .text(Transcript.TextSegment(content: "Inspect files"))
                ])),
                .toolCalls(Transcript.ToolCalls([call])),
                .toolOutput(Transcript.ToolOutput(
                    id: call.id,
                    toolName: call.toolName,
                    segments: [.text(Transcript.TextSegment(content: "README.md"))]
                ))
            ]
        )
        let messages = try #require(capture.body["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls.count == 1)
        #expect(calls.first?["id"] as? String == call.id)
        #expect(assistant["reasoning_content"] as? String == "Inspect files")
        #expect(assistant["content"] == nil)
        let output = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(output["tool_call_id"] as? String == call.id)
        #expect(output["content"] as? String == "README.md")
    }

    private static let userPrompt = "WIRE_USER_PROMPT"

    private func captureRequest(
        safariEnabled: Bool,
        history: [Transcript.Entry] = []
    ) async throws -> WireCapture {
        PromptWireURLProtocol.reset()
        defer { PromptWireURLProtocol.reset() }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PromptWireURLProtocol.self]
        let model = ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "https://wire.invalid")!,
            supportsGuidedGeneration: false,
            urlSessionConfiguration: sessionConfiguration
        )
        let workspaceInstructions = WorkspaceInstructions(
            relativePath: "AGENTS.md",
            content: "Wire-level workspace instruction.",
            revision: FileRevision.hash("Wire-level workspace instruction.")
        )
        let systemPrompt = TurboCodeSystemPromptBuilder.build(
            TurboCodeSystemPromptContext(
                role: .standalone,
                backend: .llamaServer,
                workspaceRoot: "/wire-workspace",
                agentTuning: .default,
                toolIDs: [.listWorkspace],
                toolNames: ["list_workspace"],
                availableSkills: [],
                workspaceInstructions: workspaceInstructions,
                reasoningEffort: .xhigh
            )
        )
        let toolPlan = ModelToolPlan(
            profile: .standalone,
            tier: .standard,
            assignments: [
                ModelToolAssignment(
                    id: .listWorkspace,
                    isRegistered: true,
                    unavailableReason: nil
                )
            ]
        )
        let session = LanguageModelSession(
            profile: StandaloneProfile(
                instructions: systemPrompt,
                diskSkills: [],
                workspaceRoot: "/wire-workspace",
                model: model,
                temperature: nil,
                samplingMode: nil,
                reasoningLevel: nil,
                dropsCompletedToolCalls: false,
                executionPolicy: ExecutionPolicy(),
                gitPolicy: GitPolicy(),
                toolReceiptRegistry: ToolReceiptRegistry(),
                toolPlan: toolPlan,
                usesExclusiveToolSelection: true,
                supplementalTools: [
                    ListWorkspaceTool(workspaceRoot: "/wire-workspace")
                ],
                safariSkillActivations: safariEnabled ? SkillActivations() : nil,
                onToolStart: nil,
                onToolEnd: nil
            ),
            history: history
        )

        _ = try await session.respond(to: Self.userPrompt)
        let request = try #require(PromptWireURLProtocol.capturedRequest())
        let data = try #require(request.body)
        let body = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        return WireCapture(
            url: request.url,
            method: request.method,
            body: body,
            expectedSystemPrompt: systemPrompt
        )
    }

    private func toolNames(in body: [String: Any]) -> Set<String> {
        let tools = body["tools"] as? [[String: Any]] ?? []
        return Set(tools.compactMap { tool in
            let function = tool["function"] as? [String: Any]
            return function?["name"] as? String
        })
    }

    private func textSegments(in message: [String: Any]) -> [String] {
        if let text = message["content"] as? String {
            return [text]
        }
        let content = message["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }
    }
}

private struct WireCapture {
    let url: URL
    let method: String
    let body: [String: Any]
    let expectedSystemPrompt: String
}

/// Captures the encoded request at the URL-loading boundary and returns a
/// minimal valid SSE response. The test therefore covers the real transcript
/// conversion and request encoder without depending on an external server.
private final class PromptWireURLProtocol: URLProtocol, @unchecked Sendable {
    struct CapturedRequest {
        let url: URL
        let method: String
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequest: CapturedRequest?

    static func reset() {
        lock.withLock {
            storedRequest = nil
        }
    }

    static func capturedRequest() -> CapturedRequest? {
        lock.withLock { storedRequest }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "wire.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.withLock {
            Self.storedRequest = CapturedRequest(
                url: url,
                method: request.httpMethod ?? "",
                body: Self.bodyData(from: request)
            )
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        let stream = """
        data: {"id":"wire-response","model":"wire-model","choices":[{"delta":{"role":"assistant","content":"ok"}}]}

        data: [DONE]

        """

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLSession` may hand a protocol implementation a body stream instead
    /// of the original `httpBody`; consuming it here records the exact encoded
    /// payload that would otherwise be written to the network connection.
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else {
                    return -1
                }
                return stream.read(baseAddress, maxLength: bytes.count)
            }
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
