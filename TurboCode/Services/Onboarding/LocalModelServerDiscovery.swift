import Foundation

// MARK: - Results

/// How much TurboCode can learn from a server without asking the user.
nonisolated enum LocalModelServerKind: String, Sendable, Equatable {
    /// llama.cpp's server: `/props` reports the loaded context window and
    /// vision, so nothing has to be typed during onboarding.
    case llamaServer
    /// Any other OpenAI-compatible server (LM Studio, Ollama, vLLM, …). Its
    /// context window cannot be read portably and is chosen by the user.
    case openAICompatible
}

/// A server that answered `GET /v1/models` with at least one model.
nonisolated struct DiscoveredModelServer: Sendable, Equatable, Identifiable {
    /// Normalized OpenAI base URL, always ending in `/v1`.
    let baseURL: String
    let kind: LocalModelServerKind
    /// Human label for the product, e.g. "llama-server" or "LM Studio".
    let product: String
    /// Model identifiers in the order the server listed them.
    let modelIDs: [String]
    /// `n_ctx` from llama-server's `/props`; nil for other servers.
    let contextWindowTokens: Int?
    /// Vision support from llama-server's `/props`; nil for other servers.
    let supportsVision: Bool?

    var id: String { baseURL }
    var primaryModelID: String { modelIDs.first ?? "local-model" }
}

/// One well-known local port and the product that usually listens on it.
/// The product is only a label for the list; the actual kind always comes
/// from probing, because users often run llama-server on another tool's port.
nonisolated struct LocalModelServerCandidate: Sendable, Equatable {
    let port: Int
    let product: String

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }
}

/// Outcome of the tool-calling check run on the review step.
nonisolated enum ToolCallProbeResult: Sendable, Equatable {
    case passed
    /// The server answered but returned no tool call.
    case failed
    /// The request failed or timed out.
    case unreachable
}

// MARK: - HTTP

/// The two requests discovery needs, behind a seam so tests never open
/// sockets and never depend on a model running on the developer's Mac.
nonisolated protocol OnboardingHTTPClient: Sendable {
    /// Returns the status code and body, or nil when no response arrived.
    func get(_ url: URL, timeout: TimeInterval) async -> (status: Int, body: Data)?
    func postJSON(_ url: URL, body: Data, timeout: TimeInterval) async -> (status: Int, body: Data)?
}

nonisolated struct URLSessionOnboardingHTTPClient: OnboardingHTTPClient {
    func get(_ url: URL, timeout: TimeInterval) async -> (status: Int, body: Data)? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        return await send(request)
    }

    func postJSON(_ url: URL, body: Data, timeout: TimeInterval) async -> (status: Int, body: Data)? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return await send(request)
    }

    private func send(_ request: URLRequest) async -> (status: Int, body: Data)? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }
}

// MARK: - Discovery

/// Finds OpenAI-compatible model servers for first-launch onboarding.
///
/// Discovery is read-only: it sends `GET /v1/models` and `GET /props` to
/// loopback ports and to one address the user types. The tool-call probe is
/// the only request that runs inference and is started explicitly by the
/// review step, never by the scan. No credentials are sent anywhere.
nonisolated struct LocalModelServerDiscovery: Sendable {
    /// Ports scanned on 127.0.0.1. 8080 and 9931 are common llama-server
    /// choices; the others are the defaults of popular local servers.
    static let candidates: [LocalModelServerCandidate] = [
        .init(port: 8080, product: "llama-server"),
        .init(port: 9931, product: "llama-server"),
        .init(port: 1234, product: "LM Studio"),
        .init(port: 11434, product: "Ollama"),
        .init(port: 8000, product: "vLLM"),
        .init(port: 1337, product: "Jan"),
    ]

    /// Short: a closed loopback port is refused immediately, and a server that
    /// is still loading a model is better reported as "not running" than
    /// allowed to stall the sheet.
    static let listTimeout: TimeInterval = 1.5
    /// Generous: the probe waits for real generation on a local model.
    static let toolCallTimeout: TimeInterval = 45

    let http: any OnboardingHTTPClient

    init(http: any OnboardingHTTPClient = URLSessionOnboardingHTTPClient()) {
        self.http = http
    }

    /// Probes every candidate concurrently and reports each one as soon as it
    /// finishes, so the sheet can fill in while slower ports are still pending.
    func scanLocalhost() -> AsyncStream<(LocalModelServerCandidate, DiscoveredModelServer?)> {
        let candidates = Self.candidates
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: (LocalModelServerCandidate, DiscoveredModelServer?).self) { group in
                    for candidate in candidates {
                        group.addTask {
                            (candidate, await probe(baseURL: candidate.baseURL, productHint: candidate.product))
                        }
                    }
                    for await result in group {
                        continuation.yield(result)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Probes one server. Returns nil unless it lists at least one model.
    /// - Parameter productHint: Label used when the server is not llama-server.
    func probe(baseURL: String, productHint: String? = nil) async -> DiscoveredModelServer? {
        guard let base = Self.normalizedBaseURL(baseURL),
              let baseValue = URL(string: base),
              let listing = await http.get(
                  baseValue.appendingPathComponent("models"),
                  timeout: Self.listTimeout
              ),
              (200..<300).contains(listing.status) else { return nil }
        let modelIDs = Self.modelIDs(fromListing: listing.body)
        guard !modelIDs.isEmpty else { return nil }

        // `/props` sits beside `/v1`, as in `LlamaServerRuntimeProbe`; only
        // llama-server answers it with `default_generation_settings.n_ctx`.
        let propsURL = baseValue.deletingLastPathComponent().appendingPathComponent("props")
        if let props = await http.get(propsURL, timeout: Self.listTimeout),
           (200..<300).contains(props.status),
           let object = (try? JSONSerialization.jsonObject(with: props.body)) as? [String: Any],
           let settings = object["default_generation_settings"] as? [String: Any],
           let context = (settings["n_ctx"] as? NSNumber)?.intValue,
           context > 0 {
            return DiscoveredModelServer(
                baseURL: base,
                kind: .llamaServer,
                product: "llama-server",
                modelIDs: modelIDs,
                contextWindowTokens: context,
                supportsVision: LlamaServerRuntimeProbe.supportsVision(inProps: object)
            )
        }
        return DiscoveredModelServer(
            baseURL: base,
            kind: .openAICompatible,
            product: productHint ?? "OpenAI-compatible server",
            modelIDs: modelIDs,
            contextWindowTokens: nil,
            supportsVision: nil
        )
    }

    /// Asks the model to call a trivial tool once. This is the only check that
    /// runs inference; the result is shown, not enforced, because the user may
    /// still choose to continue with a server whose tool calling is off.
    func probeToolCalling(server: DiscoveredModelServer, modelID: String) async -> ToolCallProbeResult {
        guard let base = URL(string: server.baseURL) else { return .unreachable }
        let payload: [String: Any] = [
            "model": modelID,
            "stream": false,
            // Room for reasoning models that think before calling the tool.
            "max_tokens": 1_024,
            "messages": [
                ["role": "user", "content": "Call the ping tool now. Do not answer in text."]
            ],
            "tools": [[
                "type": "function",
                "function": [
                    "name": "ping",
                    "description": "Confirms that tool calling works.",
                    "parameters": ["type": "object", "properties": [String: Any]()],
                ],
            ]],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let response = await http.postJSON(
                  base.appendingPathComponent("chat/completions"),
                  body: body,
                  timeout: Self.toolCallTimeout
              ) else { return .unreachable }
        guard (200..<300).contains(response.status) else { return .failed }
        return Self.containsToolCall(response.body) ? .passed : .failed
    }

    // MARK: Parsing

    /// Accepts what users paste: a bare host and port, a trailing slash, or a
    /// URL that already ends in `/v1`. Only http and https with a host pass.
    static func normalizedBaseURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return text.hasSuffix("/v1") ? text : text + "/v1"
    }

    static func modelIDs(fromListing data: Data) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["data"] as? [[String: Any]] else { return [] }
        return entries.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    static func containsToolCall(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let calls = message["tool_calls"] as? [Any] else { return false }
        return !calls.isEmpty
    }
}
