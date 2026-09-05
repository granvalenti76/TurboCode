import Foundation

/// The user-facing lifecycle of one delegated task attempt.
///
/// Activity is deliberately coarser than provider events: it exposes only
/// phases that are meaningful to a user and never derives progress from model
/// prose.
nonisolated enum AgentActivityPhase: String, Sendable, Hashable {
    case preparing
    case delegating
    case workerRunning
    case verifying
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            true
        case .preparing, .delegating, .workerRunning, .verifying:
            false
        }
    }

    /// Defines the complete M2 lifecycle graph. Keeping the graph beside the
    /// phase type prevents runtime adapters and views from inventing shortcuts.
    func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.preparing, .delegating),
             (.delegating, .workerRunning),
             (.workerRunning, .verifying),
             (.workerRunning, .succeeded),
             (.verifying, .succeeded):
            true
        case (.preparing, .failed),
             (.preparing, .cancelled),
             (.delegating, .failed),
             (.delegating, .cancelled),
             (.workerRunning, .failed),
             (.workerRunning, .cancelled),
             (.verifying, .failed),
             (.verifying, .cancelled):
            true
        default:
            false
        }
    }
}

/// A configured model and its deterministic role in the current route.
nonisolated struct AgentActivityAgent: Sendable, Hashable {
    let modelName: String
    let role: AgentModelRole
}

/// Identifies which side of the handoff owns a tool invocation.
nonisolated enum AgentActivityToolOwner: String, Sendable, Hashable {
    case coordinator
    case worker
}

/// The single tool invocation currently relevant to Activity presentation.
nonisolated struct AgentActivityTool: Sendable, Hashable {
    let callID: String
    let name: String
    let owner: AgentActivityToolOwner
}

/// Immutable presentation state for the current delegated attempt.
///
/// Tool receipts remain in the chat timeline; this snapshot intentionally
/// retains only current operational state and the final structured result.
nonisolated struct AgentActivity: Identifiable, Sendable, Hashable {
    let taskID: String
    let attemptID: String
    /// The structured envelope goal is the truthful task header; Activity
    /// never derives a title by parsing coordinator prose.
    let goal: String
    let verificationRequest: VerificationRequest
    let coordinator: AgentActivityAgent
    let worker: AgentActivityAgent
    var phase: AgentActivityPhase
    /// Preserves where a terminal outcome occurred without retaining a second
    /// provider event history.
    var lastOperationalPhase: AgentActivityPhase
    var activeTool: AgentActivityTool?
    let startedAt: Date
    var completedAt: Date?
    var finalResult: AgentTaskResult?

    var id: String { "\(taskID):\(attemptID)" }
}

/// Provider-neutral events consumed by the Activity state reducer.
///
/// Foundation Models and Codex adapters normalize their native callbacks into
/// this type; the store therefore never parses generated text or provider
/// transcript formats to determine operational state.
nonisolated enum AgentActivityRuntimeEvent: Sendable {
    case started(
        envelope: AgentTaskEnvelope,
        coordinator: AgentActivityAgent,
        worker: AgentActivityAgent,
        startedAt: Date
    )
    case phaseChanged(
        taskID: String,
        attemptID: String,
        phase: AgentActivityPhase
    )
    case toolStarted(
        taskID: String,
        attemptID: String,
        tool: AgentActivityTool
    )
    case toolFinished(
        taskID: String,
        attemptID: String,
        callID: String
    )
    case finished(AgentTaskResult)
}
