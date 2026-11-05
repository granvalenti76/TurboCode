import Foundation
import FoundationModels
import Network
import Testing
@testable import TurboCode

@Suite("Model request transport")
struct ModelRequestTransportTests {
    /// The two request shapes reachable by an OpenAI-compatible local endpoint:
    /// direct, and through the forwarding adapter that owns a second session.
    enum RequestPath: CaseIterable, Sendable {
        case direct
        case reasoningAdapter
    }

    @Test("Model sessions have no request or resource time limit")
    func sessionConfigurationDisablesBothLimits() {
        let configuration = ModelRequestTransport.sessionConfiguration()

        #expect(configuration.timeoutIntervalForRequest == .infinity)
        #expect(configuration.timeoutIntervalForResource == .infinity)
    }

    /// Each forwarding adapter builds its own inner session, so a default
    /// configuration there would restore the limit for that provider alone.
    @Test("Forwarding adapters do not create sessions with default time limits")
    func adaptersUseTheSharedTransportPolicy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "TurboCode/Models/ProviderLanguageModel.swift",
            "TurboCode/Models/RemoteReasoningRequestAdapter.swift"
        ]

        for path in paths {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(!source.contains("URLSession(configuration: .ephemeral"), "\(path)")
            #expect(source.contains("ModelRequestTransport.sessionConfiguration()"), "\(path)")
        }
    }

    /// Waits past the 60-second default on purpose: only a real silent socket
    /// proves that neither the outer nor the adapter session still enforces it.
    @Test(
        "A reply after more than a minute of silence is delivered",
        arguments: RequestPath.allCases
    )
    func silenceLongerThanAMinuteIsNotAFailure(path: RequestPath) async throws {
        let server = try await SilentChatServer.start(silence: .seconds(65))
        defer { server.stop() }

        let session = Self.session(path: path, port: server.port)
        var content = ""
        for try await snapshot in session.streamResponse(to: "Hello") {
            content = snapshot.content
        }

        #expect(content == "ok")
    }

    /// With no time limit, Stop is the only way out of a silent request, so it
    /// must end the wait at once and release the connection to the server.
    @Test(
        "Cancelling ends a silent request and closes its connection",
        arguments: RequestPath.allCases
    )
    func cancellationEndsASilentRequest(path: RequestPath) async throws {
        let server = try await SilentChatServer.start(silence: .seconds(30))
        defer { server.stop() }

        let session = Self.session(path: path, port: server.port)
        let clock = ContinuousClock()
        let start = clock.now
        let response = Task {
            for try await _ in session.streamResponse(to: "Hello") {}
        }

        try await Self.waitUntil { server.didReceiveRequest }
        response.cancel()
        _ = await response.result

        #expect(clock.now - start < .seconds(15))
        try await Self.waitUntil { server.didObserveDisconnect }
    }

    private static func session(path: RequestPath, port: UInt16) -> LanguageModelSession {
        let reasoning: RemoteReasoningConfiguration? = switch path {
        case .direct:
            nil
        case .reasoningAdapter:
            RemoteReasoningConfiguration(
                mode: .requestTokenBudget,
                lowTokenBudget: 128,
                mediumTokenBudget: 512,
                highTokenBudget: 2_048,
                maximumTokenBudget: 4_096
            )
        }
        let configuration = if let reasoning {
            RemoteModelConfig(
                id: "transport-test",
                name: "Transport Test",
                url: "http://127.0.0.1:\(port)/v1",
                modelName: "transport-test",
                temperature: 0.6,
                reasoningConfiguration: reasoning
            )
        } else {
            RemoteModelConfig(
                id: "transport-test",
                name: "Transport Test",
                url: "http://127.0.0.1:\(port)/v1",
                modelName: "transport-test",
                temperature: 0.6
            )
        }
        return LanguageModelSession(
            model: ProviderLanguageModel(
                configuration: configuration,
                reasoningEffort: reasoning == nil ? nil : .high
            )
        )
    }

    private static func waitUntil(
        _ condition: @Sendable () -> Bool,
        limit: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() {
            try #require(clock.now < deadline, "Condition not met in time")
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Loopback endpoint that accepts a chat request, stays completely silent like
/// `llama-server` during prompt processing, then streams one short reply.
private nonisolated final class SilentChatServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SilentChatServer")
    private let silence: Duration
    private let lock = NSLock()
    private var received = false
    private var disconnected = false
    private var connections: [NWConnection] = []

    private(set) var port: UInt16 = 0

    var didReceiveRequest: Bool { lock.withLock { received } }
    var didObserveDisconnect: Bool { lock.withLock { disconnected } }

    private init(silence: Duration) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.silence = silence
    }

    static func start(silence: Duration) async throws -> SilentChatServer {
        let server = try SilentChatServer(silence: silence)
        try await server.listen()
        return server
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    private func listen() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resume = OneShot(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    resume.finish(.success(()))
                case .failed(let error):
                    resume.finish(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        drain(connection)
    }

    /// Keeps reading so a request body split across packets is fully consumed,
    /// and so the client's disconnect is observed as soon as it happens.
    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.lock.withLock { self.disconnected = true }
                return
            }
            if data?.isEmpty == false, self.markReceived() {
                self.scheduleReply(on: connection)
            }
            self.drain(connection)
        }
    }

    /// Returns true only for the first bytes, so one request gets one reply.
    private func markReceived() -> Bool {
        lock.withLock {
            defer { received = true }
            return !received
        }
    }

    private func scheduleReply(on connection: NWConnection) {
        let silence = silence
        Task {
            try? await Task.sleep(for: silence)
            let reply = """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Connection: close\r
            \r
            data: {"id":"transport","model":"transport-test","choices":[{"delta":{"role":"assistant","content":"ok"}}]}

            data: [DONE]


            """
            connection.send(
                content: Data(reply.utf8),
                contentContext: .finalMessage,
                completion: .contentProcessed { _ in }
            )
        }
    }
}

/// Resumes a continuation once, because listener state can change repeatedly.
private nonisolated final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Void, Error>) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}
