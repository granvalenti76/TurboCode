import Foundation

/// Owns execution of the concrete backend session selected for one LLM turn.
///
/// `AgentRuntime` remains the provider-neutral owner of application operation
/// admission and lifecycle. This service is the lower execution boundary: it
/// retains the active native or Codex adapter until that adapter has completely
/// settled, and it never exposes the adapter to SwiftUI or an observable store.
/// Keeping those roles distinct prevents presentation code from becoming a
/// second cancellation or release authority.
///
/// The service is temporarily MainActor-isolated because the existing backend
/// adapters are MainActor types. A later 0.3.7 slice will move their concrete
/// session work off the UI actor while preserving this API and its single-owner
/// invariant.
@MainActor
final class LLMRuntime {
    private var activeTurnID: TurnID?
    private var activeSession: (any BackendSession)?

    var hasActiveSession: Bool {
        activeSession != nil
    }

    func ownsSession(for turnID: TurnID) -> Bool {
        activeTurnID == turnID && activeSession != nil
    }

    /// Runs exactly one backend adapter and retains it through terminal
    /// settlement. The caller may prepare presentation before entering this
    /// boundary, but it cannot release or replace the concrete provider session.
    ///
    /// Admission should already have succeeded in `AgentRuntime`. These guards
    /// still fail closed because a wiring regression must not silently replace
    /// a live provider request or execute a request with the wrong adapter.
    func execute(
        request: TurnRequest,
        using session: any BackendSession,
        events: BackendSessionEvents
    ) async -> BackendSessionResult {
        guard activeSession == nil else {
            return rejectedResult(
                code: "llm_runtime.busy",
                message: "Another LLM backend session is still active."
            )
        }
        guard session.backend == request.backend else {
            return rejectedResult(
                code: "llm_runtime.backend_mismatch",
                message: "The selected backend session does not match the admitted turn."
            )
        }

        activeTurnID = request.id
        activeSession = session
        defer { releaseSession(for: request.id) }

        return await session.run(request: request, events: events)
    }

    /// Interrupts only the adapter owned by the requested turn. Ownership is
    /// released by `execute` after the adapter unwinds, never optimistically at
    /// the moment cancellation is requested.
    func interrupt(turnID: TurnID) async {
        guard ownsSession(for: turnID), let activeSession else { return }
        await activeSession.interrupt()
    }

    private func releaseSession(for turnID: TurnID) {
        guard activeTurnID == turnID else { return }
        activeSession = nil
        activeTurnID = nil
    }

    private func rejectedResult(
        code: String,
        message: String
    ) -> BackendSessionResult {
        BackendSessionResult(
            outcome: .failed(
                TurnFailure(code: code, message: message)
            )
        )
    }
}
