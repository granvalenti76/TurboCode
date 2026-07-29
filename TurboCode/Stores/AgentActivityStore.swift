import Foundation
import Observation

/// Owns the transient, provider-independent state of one delegated attempt.
///
/// ChatStore remains responsible for the conversation transcript. This store
/// is the sole authority for Activity phase changes so asynchronous provider
/// callbacks cannot regress or resurrect a completed attempt.
@MainActor
@Observable
final class AgentActivityStore {
    private(set) var current: AgentActivity?

    /// Terminal attempt identities are retained for the lifetime of the store.
    /// This small tombstone set makes late callbacks harmless even after a
    /// newer attempt replaces the visible terminal summary.
    private var completedAttempts: Set<AttemptIdentity> = []

    /// Clears conversation-local presentation while tombstoning any attempt
    /// that was still active. A late callback from the old conversation can
    /// therefore never recreate Activity after navigation.
    func reset() {
        if let current {
            completedAttempts.insert(
                AttemptIdentity(
                    taskID: current.taskID,
                    attemptID: current.attemptID
                )
            )
        }
        current = nil
    }

    /// Reduces every provider adapter to the same typed state transitions.
    /// Returning false makes rejected or late events directly testable without
    /// exposing mutation internals to runtime integrations.
    @discardableResult
    func apply(_ event: AgentActivityRuntimeEvent) -> Bool {
        switch event {
        case .started(let envelope, let coordinator, let worker, let startedAt):
            begin(
                envelope: envelope,
                coordinator: coordinator,
                worker: worker,
                startedAt: startedAt
            )
        case .phaseChanged(let taskID, let attemptID, let phase):
            advance(taskID: taskID, attemptID: attemptID, to: phase)
        case .toolStarted(let taskID, let attemptID, let tool):
            beginTool(tool, taskID: taskID, attemptID: attemptID)
        case .toolFinished(let taskID, let attemptID, let callID):
            finishTool(
                callID: callID,
                taskID: taskID,
                attemptID: attemptID
            )
        case .finished(let result):
            complete(with: result)
        }
    }

    /// Starts an attempt only when no other attempt is running.
    @discardableResult
    func begin(
        envelope: AgentTaskEnvelope,
        coordinator: AgentActivityAgent,
        worker: AgentActivityAgent,
        startedAt: Date = Date()
    ) -> Bool {
        let identity = AttemptIdentity(envelope)
        guard !completedAttempts.contains(identity),
              current?.phase.isTerminal != false else {
            return false
        }

        current = AgentActivity(
            taskID: envelope.taskID,
            attemptID: envelope.attemptID,
            goal: envelope.goal,
            verificationRequest: envelope.verificationRequest,
            coordinator: coordinator,
            worker: worker,
            phase: .preparing,
            lastOperationalPhase: .preparing,
            activeTool: nil,
            startedAt: startedAt,
            completedAt: nil,
            finalResult: nil
        )
        return true
    }

    /// Advances through a non-terminal lifecycle phase.
    ///
    /// Terminal phases must be entered through `complete(with:)` so every
    /// terminal Activity carries the corresponding structured task result.
    @discardableResult
    func advance(
        taskID: String,
        attemptID: String,
        to phase: AgentActivityPhase
    ) -> Bool {
        guard !phase.isTerminal,
              matchesCurrent(taskID: taskID, attemptID: attemptID),
              let current,
              current.phase.canTransition(to: phase) else {
            return false
        }

        self.current?.phase = phase
        self.current?.lastOperationalPhase = phase
        return true
    }

    /// Records the currently executing tool without adding a second receipt
    /// history beside the chat timeline.
    @discardableResult
    func beginTool(
        _ tool: AgentActivityTool,
        taskID: String,
        attemptID: String
    ) -> Bool {
        guard matchesActive(taskID: taskID, attemptID: attemptID) else {
            return false
        }
        current?.activeTool = tool
        return true
    }

    /// Clears only the matching invocation; an out-of-order completion for an
    /// older tool must not hide a newer active tool.
    @discardableResult
    func finishTool(
        callID: String,
        taskID: String,
        attemptID: String
    ) -> Bool {
        guard matchesActive(taskID: taskID, attemptID: attemptID),
              current?.activeTool?.callID == callID else {
            return false
        }
        current?.activeTool = nil
        return true
    }

    /// Maps the typed task result to exactly one terminal Activity phase.
    @discardableResult
    func complete(with result: AgentTaskResult) -> Bool {
        guard matchesCurrent(
            taskID: result.taskID,
            attemptID: result.attemptID
        ), let current else {
            return false
        }

        let terminalPhase = Self.terminalPhase(for: result.outcome)
        guard current.phase.canTransition(to: terminalPhase) else {
            return false
        }

        self.current?.phase = terminalPhase
        self.current?.activeTool = nil
        self.current?.completedAt = .now
        self.current?.finalResult = result
        completedAttempts.insert(
            AttemptIdentity(taskID: result.taskID, attemptID: result.attemptID)
        )
        return true
    }

    private func matchesCurrent(taskID: String, attemptID: String) -> Bool {
        guard let current else { return false }
        return current.taskID == taskID && current.attemptID == attemptID
    }

    private func matchesActive(taskID: String, attemptID: String) -> Bool {
        matchesCurrent(taskID: taskID, attemptID: attemptID)
            && current?.phase.isTerminal == false
    }

    private static func terminalPhase(
        for outcome: AgentTaskOutcome
    ) -> AgentActivityPhase {
        switch outcome {
        case .completed, .verified:
            .succeeded
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        }
    }
}

/// Task and attempt together form the correlation identity; attempt IDs alone
/// are not assumed to be globally unique across conversations.
private nonisolated struct AttemptIdentity: Sendable, Hashable {
    let taskID: String
    let attemptID: String

    init(taskID: String, attemptID: String) {
        self.taskID = taskID
        self.attemptID = attemptID
    }

    init(_ envelope: AgentTaskEnvelope) {
        self.init(taskID: envelope.taskID, attemptID: envelope.attemptID)
    }
}
