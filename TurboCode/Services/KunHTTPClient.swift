import Foundation

// MARK: - KunHTTPClient — HTTP/SSE client for the Kun runtime API

/// Stub for communicating with `kun serve` over HTTP + Server-Sent Events.
/// Will be expanded when the LLM package is integrated.
public final class KunHTTPClient {
    public static let shared = KunHTTPClient()

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(baseURL: URL = URL(string: "http://127.0.0.1:18788")!) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Threads

    public func listThreads() async throws -> [Thread] {
        let url = baseURL.appendingPathComponent("/v1/threads")
        let (_, _) = try await session.data(for: URLRequest(url: url))
        // TODO: decode response
        return []
    }

    public func createThread(workspace: String?, title: String, mode: String) async throws -> Thread {
        let url = baseURL.appendingPathComponent("/v1/threads")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any?] = [
            "workspace": workspace,
            "title": title,
            "mode": mode
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, _) = try await session.data(for: request)
        // TODO: decode response
        return Thread(title: title)
    }

    // MARK: - Messages (SSE Stream)

    public func sendMessage(
        threadId: String,
        text: String,
        model: String?,
        providerId: String?,
        mode: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = baseURL.appendingPathComponent("/v1/threads/\(threadId)/messages")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let body: [String: Any?] = [
                        "content": text,
                        "model": model,
                        "providerId": providerId,
                        "mode": mode
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        continuation.finish(throwing: HTTPError.invalidResponse)
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = String(line.dropFirst(6))
                        continuation.yield(data)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Health

    public func checkHealth() async throws -> Bool {
        let url = baseURL.appendingPathComponent("/health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Errors

    public enum HTTPError: LocalizedError {
        case invalidResponse
        case notFound
        case serverError(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid response from Kun runtime"
            case .notFound: return "Resource not found"
            case .serverError(let code): return "Server error: \(code)"
            }
        }
    }
}
