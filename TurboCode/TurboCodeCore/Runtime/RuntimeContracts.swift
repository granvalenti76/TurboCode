import Foundation

/// Stable identity shared by every event belonging to one accepted turn.
///
/// Provider callbacks use different identifiers, so the harness owns this
/// value and carries it across adapters. Keeping the identity separate from a
/// provider request prevents a late callback from updating a newer turn.
nonisolated struct TurnID: Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init() {
        self.init(rawValue: UUID().uuidString)
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

/// Lifecycle phases owned by the harness rather than by a model provider.
nonisolated enum TurnPhase: String, Codable, Hashable, Sendable {
    case accepted
    case preparing
    case streaming
    case toolExecuting
    case awaitingApproval
    case settling
    case completed
    case cancelled
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        case .accepted, .preparing, .streaming, .toolExecuting,
             .awaitingApproval, .settling:
            false
        }
    }

    /// Keeps lifecycle transitions deterministic across all provider adapters.
    func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.accepted, .preparing),
             (.preparing, .streaming),
             (.streaming, .toolExecuting),
             (.streaming, .awaitingApproval),
             (.streaming, .settling),
             (.toolExecuting, .streaming),
             (.toolExecuting, .awaitingApproval),
             (.toolExecuting, .settling),
             (.awaitingApproval, .toolExecuting),
             (.awaitingApproval, .streaming),
             (.awaitingApproval, .settling),
             (.settling, .completed):
            true
        case (.accepted, .cancelled),
             (.accepted, .failed),
             (.preparing, .cancelled),
             (.preparing, .failed),
             (.streaming, .cancelled),
             (.streaming, .failed),
             (.toolExecuting, .cancelled),
             (.toolExecuting, .failed),
             (.awaitingApproval, .cancelled),
             (.awaitingApproval, .failed),
             (.settling, .cancelled),
             (.settling, .failed):
            true
        default:
            false
        }
    }
}

/// Immutable provider-neutral input captured when a turn is admitted.
nonisolated struct TurnRequest: Codable, Hashable, Sendable {
    let id: TurnID
    let prompt: String
    let backend: ModelBackend
    let modelName: String
    let workspaceRoot: String
    let createdAt: Date

    init(
        id: TurnID = TurnID(),
        prompt: String,
        backend: ModelBackend,
        modelName: String,
        workspaceRoot: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.prompt = prompt
        self.backend = backend
        self.modelName = modelName
        self.workspaceRoot = workspaceRoot
        self.createdAt = createdAt
    }
}

/// Provider-neutral backend selection carried by a runtime command.
///
/// The display name is intentionally optional and non-authoritative: runtime
/// ownership needs the selected backend and, when applicable, the configured
/// model identifier, but no provider session or UI profile object crosses this
/// boundary.
nonisolated struct RuntimeBackendSelection: Codable, Hashable, Sendable {
    let backend: ModelBackend
    let modelName: String?

    init(backend: ModelBackend, modelName: String? = nil) {
        self.backend = backend
        self.modelName = modelName
    }
}

/// Commands translated from UI intent into provider-neutral runtime work.
///
/// These values describe ownership and lifecycle intent only. They do not
/// execute work, retain closures, or expose Foundation Models/Codex request
/// types, so the compatibility facade can later forward them to an actor.
nonisolated enum RuntimeCommand: Codable, Hashable, Sendable {
    case submit(TurnRequest)
    case cancel(turnID: TurnID)
    case switchThread(threadID: String?)
    case switchBackend(RuntimeBackendSelection)
    case restore(threadID: String)
}

/// Structured failure information that can cross actor and provider
/// boundaries without retaining an Error value or a provider transport type.
nonisolated struct TurnFailure: Codable, Hashable, Sendable {
    let code: String
    let message: String
    let isRecoverable: Bool

    init(code: String, message: String, isRecoverable: Bool = false) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
    }
}

/// Provider-neutral result of a turn.
nonisolated enum TurnOutcome: Codable, Hashable, Sendable {
    case succeeded
    case cancelled(reason: String?)
    case failed(TurnFailure)

    var terminalPhase: TurnPhase {
        switch self {
        case .succeeded:
            .completed
        case .cancelled:
            .cancelled
        case .failed:
            .failed
        }
    }
}

/// Current runtime state projected from the accepted turn and its events.
nonisolated struct TurnState: Codable, Hashable, Sendable {
    let id: TurnID
    let phase: TurnPhase
    let startedAt: Date
    let updatedAt: Date
    let outcome: TurnOutcome?

    init(
        id: TurnID,
        phase: TurnPhase = .accepted,
        startedAt: Date,
        updatedAt: Date? = nil,
        outcome: TurnOutcome? = nil
    ) {
        self.id = id
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.outcome = outcome
    }

    /// Returns nil instead of silently accepting an invalid lifecycle jump.
    func transitioning(to next: TurnPhase, at date: Date) -> Self? {
        guard outcome == nil, phase.canTransition(to: next) else { return nil }
        return Self(
            id: id,
            phase: next,
            startedAt: startedAt,
            updatedAt: date
        )
    }

    /// Terminal transitions carry the structured outcome that explains them.
    func finishing(with outcome: TurnOutcome, at date: Date) -> Self? {
        guard self.outcome == nil,
              phase.canTransition(to: outcome.terminalPhase) else {
            return nil
        }
        return Self(
            id: id,
            phase: outcome.terminalPhase,
            startedAt: startedAt,
            updatedAt: date,
            outcome: outcome
        )
    }
}

/// Immutable runtime projection consumed by a presentation facade.
///
/// This is deliberately smaller than a transcript or a SwiftUI store. The
/// active thread and backend identify the runtime context, while `turn` and
/// the operation flags describe lifecycle ownership needed to reject stale work,
/// drive presentation controls, and coordinate transitions. Timeline blocks
/// remain a separate projection.
nonisolated struct RuntimeSnapshot: Codable, Hashable, Sendable {
    let activeThreadID: String?
    let backend: ModelBackend
    let turn: TurnState?
    let hasActiveOperation: Bool
    let isQuiescing: Bool
    let updatedAt: Date

    init(
        activeThreadID: String? = nil,
        backend: ModelBackend,
        turn: TurnState? = nil,
        hasActiveOperation: Bool = false,
        isQuiescing: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.activeThreadID = activeThreadID
        self.backend = backend
        self.turn = turn
        self.hasActiveOperation = hasActiveOperation
        self.isQuiescing = isQuiescing
        self.updatedAt = updatedAt
    }
}

/// Pure lifecycle reducer used by runtime owners before they publish a
/// `RuntimeSnapshot`.
///
/// The reducer owns no tasks, provider sessions, or UI state. Callers provide
/// event times explicitly so lifecycle tests remain deterministic and a stale
/// callback can be rejected without mutating the current turn.
nonisolated struct TurnStateReducer: Sendable {
    private(set) var state: TurnState?

    init(state: TurnState? = nil) {
        self.state = state
    }

    mutating func begin(_ request: TurnRequest) {
        state = TurnState(
            id: request.id,
            startedAt: request.createdAt
        )
    }

    mutating func reset() {
        state = nil
    }

    @discardableResult
    mutating func advance(
        to phase: TurnPhase,
        turnID: TurnID,
        at date: Date
    ) -> Bool {
        guard let state,
              state.id == turnID,
              let next = state.transitioning(to: phase, at: date) else {
            return false
        }
        self.state = next
        return true
    }

    @discardableResult
    mutating func finish(
        with outcome: TurnOutcome,
        turnID: TurnID,
        at date: Date
    ) -> Bool {
        guard let state,
              state.id == turnID,
              let next = state.finishing(with: outcome, at: date) else {
            return false
        }
        self.state = next
        return true
    }

    func owns(_ turnID: TurnID) -> Bool {
        state?.id == turnID && state?.outcome == nil
    }
}

/// A provider-neutral tool invocation captured at the harness boundary.
nonisolated struct ToolCall: Codable, Hashable, Sendable {
    let id: String
    let turnID: TurnID
    let name: String
    /// Arguments are retained as serialized JSON so no provider argument type
    /// leaks into the runtime contract.
    let argumentsJSON: String
    let startedAt: Date

    init(
        id: String,
        turnID: TurnID,
        name: String,
        argumentsJSON: String = "{}",
        startedAt: Date = Date()
    ) {
        self.id = id
        self.turnID = turnID
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.startedAt = startedAt
    }
}

/// Typed, provider-neutral output that a host may project into a native widget.
///
/// Receipts travel with the owning ``ToolResult``. They are never inferred from
/// display text and cannot bypass the runtime's TurnID acceptance gate.
nonisolated enum ToolReceipt: Codable, Hashable, Sendable {
    case workspaceListing(WorkspaceListingBlock)
    case pluginWidget(TypeScriptPluginWidgetReceipt)
}

/// Normalized completion of a tool invocation.
nonisolated struct ToolResult: Codable, Hashable, Sendable {
    nonisolated enum Status: String, Codable, Hashable, Sendable {
        case succeeded
        case failed
        case cancelled
    }

    let id: String
    let turnID: TurnID
    let status: Status
    let output: String
    let errorMessage: String?
    let durationMilliseconds: Int?
    let receipt: ToolReceipt?

    init(
        id: String,
        turnID: TurnID,
        status: Status,
        output: String = "",
        errorMessage: String? = nil,
        durationMilliseconds: Int? = nil,
        receipt: ToolReceipt? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.status = status
        self.output = output
        self.errorMessage = errorMessage
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.receipt = receipt
    }
}

/// A destructive or otherwise consequential operation awaiting user review.
nonisolated struct Approval: Codable, Hashable, Sendable {
    let id: String
    let turnID: TurnID
    let toolCallID: String
    let operation: String
    let path: String?
    let destination: String?
    let summary: String
    let requestedAt: Date

    init(
        id: String,
        turnID: TurnID,
        toolCallID: String,
        operation: String,
        path: String? = nil,
        destination: String? = nil,
        summary: String,
        requestedAt: Date = Date()
    ) {
        self.id = id
        self.turnID = turnID
        self.toolCallID = toolCallID
        self.operation = operation
        self.path = path
        self.destination = destination
        self.summary = summary
        self.requestedAt = requestedAt
    }
}

/// Optional token counters normalized across provider-specific usage models.
nonisolated struct Usage: Codable, Hashable, Sendable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?

    init(
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens.map { max(0, $0) }
        self.cachedInputTokens = cachedInputTokens.map { max(0, $0) }
        self.outputTokens = outputTokens.map { max(0, $0) }
    }

    var totalTokens: Int? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }
}

/// Context occupancy shared by local and remote backends.
nonisolated struct ContextUsage: Codable, Hashable, Sendable {
    let usedTokens: Int
    let contextSize: Int

    init(usedTokens: Int, contextSize: Int) {
        self.usedTokens = max(0, usedTokens)
        self.contextSize = max(1, contextSize)
    }

    var fraction: Double {
        min(max(Double(usedTokens) / Double(contextSize), 0), 1)
    }
}

/// Events emitted by runtime adapters after provider-specific normalization.
nonisolated enum AgentRuntimeEvent: Sendable {
    case started(TurnRequest)
    case phaseChanged(turnID: TurnID, phase: TurnPhase, at: Date)
    case toolStarted(ToolCall)
    case toolFinished(ToolResult)
    case assistantTextChanged(turnID: TurnID, text: String)
    case reasoningTextChanged(turnID: TurnID, text: String)
    case approvalRequested(Approval)
    case usageUpdated(
        turnID: TurnID,
        usage: Usage?,
        context: ContextUsage?,
        at: Date
    )
    case completed(turnID: TurnID, outcome: TurnOutcome, at: Date)

    var turnID: TurnID {
        switch self {
        case .started(let request):
            request.id
        case .phaseChanged(let turnID, _, _),
             .assistantTextChanged(let turnID, _),
             .reasoningTextChanged(let turnID, _),
             .usageUpdated(let turnID, _, _, _),
             .completed(let turnID, _, _):
            turnID
        case .toolStarted(let call):
            call.turnID
        case .toolFinished(let result):
            result.turnID
        case .approvalRequested(let approval):
            approval.turnID
        }
    }
}

/// Provider-neutral terminal payload returned by one backend session.
/// Provider adapters may keep richer diagnostics internally, but the harness
/// only needs the visible text and the typed lifecycle outcome at this seam.
nonisolated struct BackendSessionResult: Codable, Hashable, Sendable {
    let assistantText: String
    let reasoningText: String
    let outcome: TurnOutcome

    init(
        assistantText: String = "",
        reasoningText: String = "",
        outcome: TurnOutcome
    ) {
        self.assistantText = assistantText
        self.reasoningText = reasoningText
        self.outcome = outcome
    }
}

/// Prevents an independent worker result from being published after its turn
/// was cancelled or replaced by a newer application command.
nonisolated enum TurnCompletionPolicy {
    static func accepts(
        turnID: TurnID,
        activeTurnID: TurnID?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && activeTurnID == turnID
    }
}
