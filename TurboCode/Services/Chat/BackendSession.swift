import Foundation

/// Ordered event sink used by the application's in-process provider adapters.
///
/// The normalized event values belong to TurboCodeCore, but current Foundation
/// Presentation projection remains an explicit output port. Its closure is
/// MainActor-isolated because the current consumer reduces events into UI state,
/// while the session invoking it is free to execute on its own actor.
nonisolated struct BackendSessionEvents: Sendable {
    static let none = BackendSessionEvents()

    /// Backpressure is intentional: a provider must not overtake lifecycle
    /// reduction or publish completion before earlier stream/tool events settle.
    let emit: @MainActor @Sendable (AgentRuntimeEvent) async -> Void

    init(
        emit: @escaping @MainActor @Sendable (
            AgentRuntimeEvent
        ) async -> Void = { _ in }
    ) {
        self.emit = emit
    }
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
}
