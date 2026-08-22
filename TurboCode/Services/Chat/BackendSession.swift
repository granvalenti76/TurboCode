import Foundation

/// MainActor event sink used by the application's in-process provider adapters.
///
/// The normalized event values belong to TurboCodeCore, but current Foundation
/// Models and Codex adapters still publish through application-owned MainActor
/// coordinators. Keeping this bridge outside the core makes that temporary
/// isolation dependency visible until the execution runtime removes it.
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
@MainActor
protocol BackendSession: AnyObject {
    var backend: ModelBackend { get }

    func run(
        request: TurnRequest,
        events: BackendSessionEvents
    ) async -> BackendSessionResult

    func interrupt() async
}
