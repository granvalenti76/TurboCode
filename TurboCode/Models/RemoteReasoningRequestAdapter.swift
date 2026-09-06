import Foundation

nonisolated enum RemoteReasoningRequestDirective: Equatable, Sendable {
    case disabled
    case tokenBudget(Int)
}

nonisolated extension RemoteReasoningConfiguration {
    /// Resolves the selected product level without inspecting the model name.
    /// Returning nil is significant: server-managed endpoints receive the
    /// original OpenAI-compatible payload byte-for-byte.
    func requestDirective(
        for effort: ReasoningEffort?
    ) -> RemoteReasoningRequestDirective? {
        guard mode == .requestTokenBudget else { return nil }
        return switch effort {
        case .low:
            .tokenBudget(lowTokenBudget)
        case .medium:
            .tokenBudget(mediumTokenBudget)
        case .high:
            .tokenBudget(highTokenBudget)
        case .xhigh:
            .tokenBudget(maximumTokenBudget ?? -1)
        case nil:
            .disabled
        }
    }
}

/// Pure JSON mutation kept separate from URL loading so the exact provider
/// payload can be covered by focused tests.
nonisolated enum RemoteReasoningRequestBody {
    static func adapt(
        _ data: Data,
        directive: RemoteReasoningRequestDirective
    ) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteReasoningRequestAdapterError.invalidRequestBody
        }
        var templateArguments = object["chat_template_kwargs"] as? [String: Any] ?? [:]
        switch directive {
        case .disabled:
            templateArguments["enable_thinking"] = false
            object.removeValue(forKey: "thinking_budget_tokens")
        case .tokenBudget(let tokens):
            templateArguments["enable_thinking"] = true
            object["thinking_budget_tokens"] = tokens
        }
        object["chat_template_kwargs"] = templateArguments
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// Request-scoped adapter for endpoints whose chat template accepts a thinking
/// switch and token budget. The internal control headers are removed before
/// forwarding and never reach the provider.
nonisolated final class RemoteReasoningRequestAdapter: URLProtocol,
    URLSessionDataDelegate,
    @unchecked Sendable {
    static let adapterHeader = "X-TurboCode-Reasoning-Adapter"
    static let directiveHeader = "X-TurboCode-Reasoning-Directive"
    private static let handledKey = "TurboCodeReasoningRequestHandled"

    private var dataTask: URLSessionDataTask?
    private var session: URLSession?

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: adapterHeader) == "token-budget"
            && URLProtocol.property(forKey: handledKey, in: request) == nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        do {
            let directive = try Self.directive(from: mutable)
            mutable.setValue(nil, forHTTPHeaderField: Self.adapterHeader)
            mutable.setValue(nil, forHTTPHeaderField: Self.directiveHeader)
            guard let body = Self.requestBody(from: mutable) else {
                throw RemoteReasoningRequestAdapterError.invalidRequestBody
            }
            mutable.httpBodyStream = nil
            mutable.httpBody = try RemoteReasoningRequestBody.adapt(
                body,
                directive: directive
            )
            URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

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
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        session.finishTasksAndInvalidate()
    }

    private static func directive(
        from request: NSMutableURLRequest
    ) throws -> RemoteReasoningRequestDirective {
        guard let value = request.value(forHTTPHeaderField: directiveHeader) else {
            throw RemoteReasoningRequestAdapterError.invalidDirective
        }
        if value == "disabled" { return .disabled }
        guard let tokens = Int(value), tokens == -1 || tokens > 0 else {
            throw RemoteReasoningRequestAdapterError.invalidDirective
        }
        return .tokenBudget(tokens)
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
}

nonisolated private enum RemoteReasoningRequestAdapterError: LocalizedError {
    case invalidDirective
    case invalidRequestBody

    var errorDescription: String? {
        switch self {
        case .invalidDirective:
            "The reasoning request directive is invalid."
        case .invalidRequestBody:
            "The chat-completions request body could not be adapted."
        }
    }
}
