import Foundation
import Observation

/// Owns transient, provider-independent state for delegated attempts.
///
/// ChatStore remains responsible for the conversation transcript. This store
/// is the sole authority for Activity phase changes so asynchronous provider
/// callbacks cannot regress or resurrect a completed attempt.
@MainActor
@Observable
final class AgentActivityStore {
    private(set) var activities: [AgentActivity] = []
    private(set) var selectedActivityID: String?

    /// Compatibility projection used by compact UI and existing integrations.
    /// Prefer the explicit selection, then the newest running task, then the
    /// latest terminal task.
    var current: AgentActivity? {
        if let selectedActivityID,
           let selected = activities.first(where: {
               $0.id == selectedActivityID
           }) {
            return selected
        }
        return activities.last(where: { !$0.phase.isTerminal })
            ?? activities.last
    }

    /// Terminal attempt identities are retained for the lifetime of the store.
    /// This small tombstone set makes late callbacks harmless even after a
    /// newer attempt replaces the visible terminal summary.
    private var completedAttempts: Set<AttemptIdentity> = []

    /// Clears conversation-local presentation while tombstoning any attempt
    /// that was still active. A late callback from the old conversation can
    /// therefore never recreate Activity after navigation.
    func reset() {
        for activity in activities where !activity.phase.isTerminal {
            completedAttempts.insert(
                AttemptIdentity(
                    taskID: activity.taskID,
                    attemptID: activity.attemptID
                )
            )
        }
        activities = []
        selectedActivityID = nil
    }

    func select(_ id: String) {
        guard activities.contains(where: { $0.id == id }) else { return }
        selectedActivityID = id
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

    /// Starts an attempt unless that same correlated attempt already exists.
    @discardableResult
    func begin(
        envelope: AgentTaskEnvelope,
        coordinator: AgentActivityAgent,
        worker: AgentActivityAgent,
        startedAt: Date = Date()
    ) -> Bool {
        let identity = AttemptIdentity(envelope)
        guard !completedAttempts.contains(identity),
              !activities.contains(where: { $0.id == identity.rawValue }) else {
            return false
        }

        // Activity is a transient operational surface, not a second task
        // ledger. Retain a compact recent window while never evicting work
        // that is still running.
        if activities.count >= 20,
           let terminalIndex = activities.firstIndex(where: {
               $0.phase.isTerminal
           }) {
            activities.remove(at: terminalIndex)
        }

        let activity = AgentActivity(
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
        activities.append(activity)
        selectedActivityID = activity.id
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
              let index = index(taskID: taskID, attemptID: attemptID),
              activities[index].phase.canTransition(to: phase) else {
            return false
        }

        activities[index].phase = phase
        activities[index].lastOperationalPhase = phase
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
        guard let index = activeIndex(
            taskID: taskID,
            attemptID: attemptID
        ) else {
            return false
        }
        activities[index].activeTool = tool
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
        guard let index = activeIndex(
            taskID: taskID,
            attemptID: attemptID
        ), activities[index].activeTool?.callID == callID else {
            return false
        }
        activities[index].activeTool = nil
        return true
    }

    /// Maps the typed task result to exactly one terminal Activity phase.
    @discardableResult
    func complete(with result: AgentTaskResult) -> Bool {
        guard let index = index(
            taskID: result.taskID,
            attemptID: result.attemptID
        ) else {
            return false
        }

        let terminalPhase = Self.terminalPhase(for: result.outcome)
        guard activities[index].phase.canTransition(to: terminalPhase) else {
            return false
        }

        activities[index].phase = terminalPhase
        activities[index].activeTool = nil
        activities[index].completedAt = .now
        activities[index].finalResult = result
        completedAttempts.insert(
            AttemptIdentity(taskID: result.taskID, attemptID: result.attemptID)
        )
        return true
    }

    private func index(taskID: String, attemptID: String) -> Int? {
        activities.firstIndex {
            $0.taskID == taskID && $0.attemptID == attemptID
        }
    }

    private func activeIndex(taskID: String, attemptID: String) -> Int? {
        guard let index = index(taskID: taskID, attemptID: attemptID),
              !activities[index].phase.isTerminal else {
            return nil
        }
        return index
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

    var rawValue: String { "\(taskID):\(attemptID)" }
}
