import Foundation
import FoundationModels
import FoundationModelsUtilities

struct ProviderLanguageModel: LanguageModel {
    let configuration: RemoteModelConfig
    let apiKey: String?

    var capabilities: LanguageModelCapabilities {
        if configuration.supportsGuidedGeneration && configuration.supportsReasoning {
            LanguageModelCapabilities([.vision, .toolCalling, .reasoning, .guidedGeneration])
        } else if configuration.supportsGuidedGeneration {
            LanguageModelCapabilities([.vision, .toolCalling, .guidedGeneration])
        } else if configuration.supportsReasoning {
            LanguageModelCapabilities([.vision, .toolCalling, .reasoning])
        } else {
            LanguageModelCapabilities([.vision, .toolCalling])
        }
    }

    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(model: configuration, apiKey: apiKey)
    }

    struct Executor: LanguageModelExecutor {
        typealias Model = ProviderLanguageModel
        let configuration: Configuration

        init(configuration: Configuration) {
            self.configuration = configuration
        }

        struct Configuration: Hashable, Sendable {
            let model: RemoteModelConfig
            let apiKey: String?
        }

        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: ProviderLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            guard let url = URL(string: configuration.model.url) else {
                throw ProviderModelError.invalidURL(configuration.model.url)
            }

            var headers: [String: String] = [:]
            if let apiKey = configuration.apiKey, !apiKey.isEmpty {
                headers["Authorization"] = "Bearer \(apiKey)"
            }

            var sessionConfiguration: URLSessionConfiguration?
            if configuration.model.reasoningTransport == .deepseekThinking {
                headers[DeepSeekRequestAdapter.adapterHeader] = "deepseek"
                headers[DeepSeekRequestAdapter.reasoningHeader] = reasoningEffort(
                    request.contextOptions.reasoningLevel
                )
                let value = URLSessionConfiguration.ephemeral
                value.protocolClasses = [DeepSeekRequestAdapter.self]
                sessionConfiguration = value
            }

            let baseModel = ChatCompletionsLanguageModel(
                name: configuration.model.modelName,
                url: url,
                additionalHeaders: headers,
                supportsGuidedGeneration: configuration.model.supportsGuidedGeneration,
                urlSessionConfiguration: sessionConfiguration
            )
            let executor = ChatCompletionsLanguageModel.Executor(
                configuration: baseModel.executorConfiguration
            )
            try await executor.respond(to: request, model: baseModel, streamingInto: channel)
        }

        private func reasoningEffort(_ level: ContextOptions.ReasoningLevel?) -> String {
            switch level {
            case .light: "low"
            case .moderate: "medium"
            case .deep: "high"
            case .custom(let value): value
            case nil: "disabled"
            @unknown default: "medium"
            }
        }
    }
}

private enum ProviderModelError: LocalizedError {
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): "Invalid model URL: \(value)"
        }
    }
}

nonisolated final class DeepSeekRequestAdapter: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    static let adapterHeader = "X-TurboCode-Provider-Adapter"
    static let reasoningHeader = "X-TurboCode-Reasoning-Effort"
    private static let handledKey = "TurboCodeDeepSeekRequestHandled"

    private var dataTask: URLSessionDataTask?
    private var session: URLSession?
    private var streamBuffer = Data()
    private var capturedReasoning = ""
    private var capturedToolCalls: [Int: CapturedDeepSeekToolCall] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: adapterHeader) == "deepseek"
            && URLProtocol.property(forKey: handledKey, in: request) == nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        let effort = mutable.value(forHTTPHeaderField: Self.reasoningHeader) ?? "disabled"
        mutable.setValue(nil, forHTTPHeaderField: Self.adapterHeader)
        mutable.setValue(nil, forHTTPHeaderField: Self.reasoningHeader)
        Self.adaptBody(of: mutable, effort: effort)
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        self.session = session
        dataTask = session.dataTask(with: mutable as URLRequest)
        dataTask?.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        streamBuffer.append(data)
        flushCompleteLines()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if !streamBuffer.isEmpty {
            captureResponseMetadata(in: streamBuffer)
            client?.urlProtocol(self, didLoad: Self.adaptUsage(in: streamBuffer))
            streamBuffer.removeAll(keepingCapacity: false)
        }
        DeepSeekToolCallRegistry.shared.store(
            Array(capturedToolCalls.values),
            reasoning: capturedReasoning
        )
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        session.finishTasksAndInvalidate()
    }

    private func flushCompleteLines() {
        while let newline = streamBuffer.firstIndex(of: 0x0A) {
            let line = Data(streamBuffer[..<newline])
            streamBuffer.removeSubrange(...newline)
            captureResponseMetadata(in: line)
            var output = Self.adaptUsage(in: line)
            output.append(0x0A)
            client?.urlProtocol(self, didLoad: output)
        }
    }

    private static func adaptBody(of request: NSMutableURLRequest, effort: String) {
        guard let body = requestBody(from: request),
              var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeDebugWireSummary(error: "Request body unavailable")
            return
        }

        if effort == "disabled" {
            object["thinking"] = ["type": "disabled"]
            object.removeValue(forKey: "reasoning_effort")
        } else {
            object["thinking"] = ["type": "enabled"]
            object["reasoning_effort"] = effort
            object.removeValue(forKey: "temperature")
            object.removeValue(forKey: "top_p")
            object.removeValue(forKey: "presence_penalty")
            object.removeValue(forKey: "frequency_penalty")
            object.removeValue(forKey: "tool_choice")
            normalizeThinkingToolMessages(in: &object)
            restoreMissingToolCallMessages(in: &object)
        }
        writeDebugWireSummary(object: object)
        request.httpBodyStream = nil
        request.httpBody = try? JSONSerialization.data(withJSONObject: object)
    }

    private static func requestBody(from request: NSMutableURLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data.isEmpty ? nil : data
    }

    private static func normalizeThinkingToolMessages(in object: inout [String: Any]) {
        guard var messages = object["messages"] as? [[String: Any]] else { return }
        var index = 0
        while index < messages.count {
            guard messages[index]["role"] as? String == "assistant",
                  let toolCalls = messages[index]["tool_calls"] as? [[String: Any]],
                  !toolCalls.isEmpty else {
                index += 1
                continue
            }

            // DeepSeek V4 requires an explicit, non-null content value on the
            // assistant message that owns tool calls. The generic OpenAI
            // encoder omits it when the assistant emitted no visible text.
            if messages[index]["content"] == nil || messages[index]["content"] is NSNull {
                messages[index]["content"] = ""
            }

            var outputStart = index + 1
            while outputStart < messages.count,
                  messages[outputStart]["role"] as? String == "assistant",
                  (messages[outputStart]["tool_calls"] as? [[String: Any]])?.isEmpty != false {
                outputStart += 1
            }
            if outputStart > index + 1,
               outputStart < messages.count,
               messages[outputStart]["role"] as? String == "tool" {
                let toolCallMessage = messages.remove(at: index)
                outputStart -= 1
                messages.insert(toolCallMessage, at: outputStart)
                index = outputStart
            }

            var endOfOutputs = index + 1
            while endOfOutputs < messages.count,
                  messages[endOfOutputs]["role"] as? String == "tool" {
                endOfOutputs += 1
            }
            let outputs = Array(messages[(index + 1)..<endOfOutputs])
            guard !outputs.isEmpty else {
#if DEBUG
                print("[DeepSeek] Dropping an incomplete historical tool-call message")
#endif
                messages.remove(at: index)
                continue
            }

            var unusedCalls = toolCalls
            var retainedCalls: [[String: Any]] = []
            var normalizedOutputs: [[String: Any]] = []
            for var output in outputs {
                let outputID = output["tool_call_id"] as? String
                let matchingIndex = outputID.flatMap { id in
                    unusedCalls.firstIndex(where: { $0["id"] as? String == id })
                }
                guard let callIndex = matchingIndex ?? unusedCalls.indices.first else { break }
                let call = unusedCalls.remove(at: callIndex)
                guard let callID = call["id"] as? String else { continue }
                output["tool_call_id"] = callID
                retainedCalls.append(call)
                normalizedOutputs.append(output)
            }

            guard !retainedCalls.isEmpty else {
                messages.removeSubrange(index..<endOfOutputs)
                continue
            }
            messages[index]["tool_calls"] = retainedCalls
            messages.replaceSubrange(
                (index + 1)..<endOfOutputs,
                with: normalizedOutputs
            )
#if DEBUG
            if retainedCalls.count != toolCalls.count || normalizedOutputs.count != outputs.count {
                print(
                    "[DeepSeek] Normalized tool exchange: "
                        + "\(toolCalls.count) calls, \(outputs.count) outputs -> "
                        + "\(retainedCalls.count) complete pairs"
                )
            }
#endif
            index += 1 + normalizedOutputs.count
        }
        object["messages"] = messages
    }

    private static func restoreMissingToolCallMessages(in object: inout [String: Any]) {
        guard var messages = object["messages"] as? [[String: Any]] else { return }
        var index = 0
        while index < messages.count {
            guard messages[index]["role"] as? String == "tool" else {
                index += 1
                continue
            }

            let groupStart = index
            var groupEnd = index
            while groupEnd < messages.count,
                  messages[groupEnd]["role"] as? String == "tool" {
                groupEnd += 1
            }
            let outputIDs = messages[groupStart..<groupEnd].compactMap {
                $0["tool_call_id"] as? String
            }
            let previousCalls = groupStart > 0
                ? messages[groupStart - 1]["tool_calls"] as? [[String: Any]]
                : nil
            let previousIDs = Set(previousCalls?.compactMap { $0["id"] as? String } ?? [])
            guard !outputIDs.allSatisfy(previousIDs.contains) else {
                index = groupEnd
                continue
            }

            let captured = outputIDs.compactMap(DeepSeekToolCallRegistry.shared.value(for:))
            guard captured.count == outputIDs.count else {
#if DEBUG
                print("[DeepSeek] Missing captured metadata for orphan tool outputs: \(outputIDs)")
#endif
                index = groupEnd
                continue
            }
            let reasoning = captured.lazy.map(\.reasoning).first(where: { !$0.isEmpty })
            var assistant: [String: Any] = [
                "role": "assistant",
                "content": "",
                "tool_calls": captured.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": call.arguments]
                    ] as [String: Any]
                }
            ]
            if let reasoning { assistant["reasoning_content"] = reasoning }
            messages.insert(assistant, at: groupStart)
#if DEBUG
            print("[DeepSeek] Restored \(captured.count) missing tool-call message(s)")
#endif
            index = groupEnd + 1
        }
        object["messages"] = messages
    }

    private func captureResponseMetadata(in line: Data) {
        guard let string = String(data: line, encoding: .utf8) else { return }
        let clean = string.hasSuffix("\r") ? String(string.dropLast()) : string
        guard clean.hasPrefix("data: "), clean != "data: [DONE]",
              let data = String(clean.dropFirst(6)).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any] else { return }

        if let reasoning = delta["reasoning_content"] as? String {
            capturedReasoning += reasoning
        }
        for item in delta["tool_calls"] as? [[String: Any]] ?? [] {
            guard let index = item["index"] as? Int else { continue }
            var call = capturedToolCalls[index] ?? CapturedDeepSeekToolCall()
            call.id += item["id"] as? String ?? ""
            if let function = item["function"] as? [String: Any] {
                call.name += function["name"] as? String ?? ""
                call.arguments += function["arguments"] as? String ?? ""
            }
            capturedToolCalls[index] = call
        }
    }

    private static func writeDebugWireSummary(
        object: [String: Any]? = nil,
        error: String? = nil
    ) {
#if DEBUG
        var summary: [String: Any] = ["createdAt": ISO8601DateFormatter().string(from: Date())]
        if let error { summary["error"] = error }
        if let object {
            summary["model"] = object["model"]
            summary["thinking"] = object["thinking"]
            summary["hasToolChoice"] = object["tool_choice"] != nil
            summary["messages"] = (object["messages"] as? [[String: Any]] ?? []).map { message in
                let calls = message["tool_calls"] as? [[String: Any]] ?? []
                return [
                    "role": message["role"] as? String ?? "unknown",
                    "toolCallIDs": calls.compactMap { $0["id"] as? String },
                    "toolOutputID": message["tool_call_id"] as? String ?? "",
                    "hasContent": message["content"] != nil && !(message["content"] is NSNull),
                    "hasReasoning": message["reasoning_content"] != nil
                        && !(message["reasoning_content"] is NSNull)
                ] as [String: Any]
            }
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode/diagnostics", isDirectory: true)
        let url = directory.appendingPathComponent("deepseek-wire-summary.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: url, options: .atomic)
        }
#endif
    }

    private static func adaptUsage(in line: Data) -> Data {
        guard let string = String(data: line, encoding: .utf8) else { return line }
        let carriageReturn = string.hasSuffix("\r")
        let clean = carriageReturn ? String(string.dropLast()) : string
        guard clean.hasPrefix("data: "), clean != "data: [DONE]" else { return line }

        let payload = String(clean.dropFirst(6))
        guard let data = payload.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var usage = object["usage"] as? [String: Any],
              let cacheHits = usage["prompt_cache_hit_tokens"] else { return line }

        var details = usage["prompt_tokens_details"] as? [String: Any] ?? [:]
        details["cached_tokens"] = cacheHits
        usage["prompt_tokens_details"] = details
        object["usage"] = usage
        guard let encoded = try? JSONSerialization.data(withJSONObject: object),
              var transformed = String(data: encoded, encoding: .utf8) else { return line }
        transformed = "data: " + transformed + (carriageReturn ? "\r" : "")
        return Data(transformed.utf8)
    }
}

nonisolated private struct CapturedDeepSeekToolCall: Sendable {
    var id = ""
    var name = ""
    var arguments = ""
    var reasoning = ""
}

nonisolated private final class DeepSeekToolCallRegistry: @unchecked Sendable {
    static let shared = DeepSeekToolCallRegistry()

    private let lock = NSLock()
    private var values: [String: CapturedDeepSeekToolCall] = [:]

    func store(_ calls: [CapturedDeepSeekToolCall], reasoning: String) {
        lock.lock()
        defer { lock.unlock() }
        for var call in calls where !call.id.isEmpty && !call.name.isEmpty {
            call.reasoning = reasoning
            values[call.id] = call
        }
        if values.count > 200 { values.removeAll(keepingCapacity: true) }
    }

    func value(for id: String) -> CapturedDeepSeekToolCall? {
        lock.lock()
        defer { lock.unlock() }
        return values[id]
    }
}
