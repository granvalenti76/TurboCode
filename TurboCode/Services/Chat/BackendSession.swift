import Foundation

/// Ordered event sink used by the application's in-process provider adapters.
///
/// The normalized event values belong to TurboCodeCore, but current Foundation
/// Presentation projection remains an explicit output port. The sink itself is
/// executor-neutral; an ingress actor admits events before the current consumer
/// reduces them into MainActor UI state.
nonisolated struct BackendSessionEvents: Sendable {
    static let none = BackendSessionEvents()

    /// Backpressure is intentional: a provider must not overtake lifecycle
    /// reduction or publish completion before earlier stream/tool events settle.
    let emit: @Sendable (AgentRuntimeEvent) async -> Void

    init(
        emit: @escaping @Sendable (
            AgentRuntimeEvent
        ) async -> Void = { _ in }
    ) {
        self.emit = emit
    }
}

/// Result of a provider steering request. A transport timeout is represented
/// as `uncertain` so callers never retry a possibly accepted input blindly.
nonisolated enum BackendSteeringResult: Sendable, Equatable {
    case accepted(providerTurnID: String?)
    case unsupported
    case failed(TurnFailure)
    case uncertain
}

/// In-process application port for one configured provider session.
///
/// This is intentionally an adapter contract, not a second transport stack:
/// existing Foundation Models and Codex runners retain their native streaming
/// and tool protocols. The port stays outside TurboCodeCore while its isolation
/// still depends on the application's MainActor presentation bridge.
nonisolated protocol BackendSession: AnyObject, Sendable {
    var backend: ModelBackend { get }

    func run(
        request: TurnRequest,
        events: BackendSessionEvents
    ) async -> BackendSessionResult

    func interrupt() async

    func steer(input: String) async -> BackendSteeringResult
}
