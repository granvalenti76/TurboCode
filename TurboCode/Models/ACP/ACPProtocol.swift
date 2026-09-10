import Foundation

/// JSON-RPC request identifiers accepted by the Agent Client Protocol.
/// Keeping the original scalar value matters because clients correlate prompt
/// completion responses by ID, including when an ID is numeric rather than a
/// string.
nonisolated enum ACPRequestID: Codable, Equatable, Hashable, Sendable {
    case number(Int)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let value = try MCPJSONValue(from: decoder)
        switch value {
        case .number(let raw):
            guard raw.rounded() == raw else {
                throw ACPProtocolError.invalidRequest("Request ID must be an integer.")
            }
            self = .number(Int(raw))
        case .string(let value): self = .string(value)
        case .null: self = .null
        default:
            throw ACPProtocolError.invalidRequest("Request ID must be a string or integer.")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .number(let value): try MCPJSONValue.number(Double(value)).encode(to: encoder)
        case .string(let value): try MCPJSONValue.string(value).encode(to: encoder)
        case .null: try MCPJSONValue.null.encode(to: encoder)
        }
    }

    var jsonValue: MCPJSONValue {
        switch self {
        case .number(let value): .number(Double(value))
        case .string(let value): .string(value)
        case .null: .null
        }
    }
}

/// Errors produced before an ACP request reaches the application driver.
nonisolated enum ACPProtocolError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case invalidParams(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .invalidParams(let message): message
        }
    }
}

/// The small, provider-neutral boundary required by the ACP wire server.
/// Application assembly supplies the implementation in a later slice; the
/// protocol layer deliberately knows nothing about SwiftUI or model stores.
nonisolated protocol ACPAgentDriver: Sendable {
    func createSession(
        cwd: String,
        mcpServers: [MCPJSONValue]
    ) async throws -> String

    func prompt(
        sessionID: String,
        prompt: [MCPJSONValue],
        updates: ACPUpdateChannel
    ) async throws -> ACPStopReason

    func cancel(sessionID: String) async
}

/// Runtime port consumed by the ACP session adapter. The concrete application
/// host supplies the existing AgentRuntime/LLMRuntime graph; this contract does
/// not create a second model loop or expose UI-owned stores to the helper.
nonisolated protocol ACPApplicationRuntime: Sendable {
    func prepareSession(
        sessionID: String,
        cwd: String,
        mcpServers: [MCPJSONValue]
    ) async throws

    func run(
        turn: ACPApplicationTurn,
        updates: ACPUpdateChannel
    ) async throws -> ACPStopReason

    func cancel(sessionID: String) async
}

nonisolated struct ACPApplicationTurn: Sendable, Equatable {
    let sessionID: String
    let turnID: TurnID
    let cwd: String
    let prompt: [MCPJSONValue]
}

/// One agent-to-client `session/update` payload. The driver emits the exact
/// ACP update params so rich content and future protocol fields are retained.
nonisolated struct ACPAgentUpdate: Equatable, Sendable {
    let sessionID: String
    let update: MCPJSONValue

    init(sessionID: String, update: MCPJSONValue) {
        self.sessionID = sessionID
        self.update = update
    }
}

/// Thread-safe bridge for live `session/update` notifications. AsyncStream's
/// continuation is safe to resume from the provider actor without imposing a
/// global-actor closure requirement on ACPAgentDriver implementations.
nonisolated final class ACPUpdateChannel: @unchecked Sendable {
    let stream: AsyncStream<ACPAgentUpdate>
    private let continuation: AsyncStream<ACPAgentUpdate>.Continuation

    init() {
        let pair = AsyncStream<ACPAgentUpdate>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func emit(_ update: ACPAgentUpdate) {
        continuation.yield(update)
    }

    func finish() {
        continuation.finish()
    }
}

nonisolated enum ACPStopReason: String, Codable, Equatable, Sendable {
    case endTurn = "end_turn"
    case cancelled
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
}
