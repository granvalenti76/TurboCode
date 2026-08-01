import Foundation

/// A deterministic verification requested by the coordinator.
///
/// Provider prompts choose only the class. Optional execution parameters travel
/// separately so omission continues to mean native project discovery.
nonisolated enum VerificationRequest: String, Codable, Sendable, Hashable {
    case none
    case build
    case test
}

/// Optional Xcode selection retained with a build or test request.
///
/// Nil fields deliberately delegate selection to the existing discovery
/// service. This contract stores choices but never treats prose as evidence.
nonisolated struct AgentVerificationParameters: Codable, Sendable, Hashable {
    let containerPath: String?
    let scheme: String?
    let configuration: String?
    let destination: String?

    init(
        containerPath: String? = nil,
        scheme: String? = nil,
        configuration: String? = nil,
        destination: String? = nil
    ) {
        self.containerPath = containerPath
        self.scheme = scheme
        self.configuration = configuration
        self.destination = destination
    }

    fileprivate func validate() throws {
        for (field, value) in [
            ("verificationParameters.containerPath", containerPath),
            ("verificationParameters.scheme", scheme),
            ("verificationParameters.configuration", configuration),
            ("verificationParameters.destination", destination)
        ] {
            guard let value else { continue }
            try AgentTaskEnvelope.requireContent(value, field: field)
        }
    }
}

/// Runtime limits that every worker adapter must enforce independently of its
/// provider prompt.
nonisolated struct DelegationBudget: Codable, Sendable, Hashable {
    static let `default` = DelegationBudget(
        timeoutSeconds: 120,
        maximumToolCalls: 12
    )

    let timeoutSeconds: Int
    let maximumToolCalls: Int

    init(timeoutSeconds: Int, maximumToolCalls: Int) {
        self.timeoutSeconds = timeoutSeconds
        self.maximumToolCalls = maximumToolCalls
    }

    func validated() throws -> Self {
        guard timeoutSeconds > 0 else {
            throw AgentTaskContractError.invalidTimeout(timeoutSeconds)
        }
        guard maximumToolCalls >= 0 else {
            throw AgentTaskContractError.invalidToolCallLimit(maximumToolCalls)
        }
        return self
    }
}

/// Provider-independent task passed from a coordinator to one sequential worker.
///
/// Arrays retain a stable order for reproducible transport. A non-empty
/// suggested scope is enforced for path-bearing worker tools; the historical
/// field name remains stable for schema compatibility.
nonisolated struct AgentTaskEnvelope: Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let taskID: String
    let attemptID: String
    let goal: String
    let acceptanceCriteria: [String]
    let suggestedScope: [String]
    let allowedTools: [ToolCapabilityID]
    let verificationRequest: VerificationRequest
    let verificationParameters: AgentVerificationParameters?
    let budget: DelegationBudget

    init(
        schemaVersion: Int = currentSchemaVersion,
        taskID: String,
        attemptID: String,
        goal: String,
        acceptanceCriteria: [String],
        suggestedScope: [String] = [],
        allowedTools: [ToolCapabilityID] = [],
        verificationRequest: VerificationRequest = .none,
        verificationParameters: AgentVerificationParameters? = nil,
        budget: DelegationBudget = .default
    ) throws {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.attemptID = attemptID
        self.goal = goal
        self.acceptanceCriteria = acceptanceCriteria
        self.suggestedScope = suggestedScope
        self.allowedTools = Self.uniqued(allowedTools)
        self.verificationRequest = verificationRequest
        self.verificationParameters = verificationParameters
        self.budget = budget
        try validate()
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        taskID = try values.decode(String.self, forKey: .taskID)
        attemptID = try values.decode(String.self, forKey: .attemptID)
        goal = try values.decode(String.self, forKey: .goal)
        acceptanceCriteria = try values.decodeIfPresent(
            [String].self,
            forKey: .acceptanceCriteria
        ) ?? []
        suggestedScope = try values.decodeIfPresent([String].self, forKey: .suggestedScope) ?? []
        allowedTools = Self.uniqued(
            try values.decodeIfPresent([ToolCapabilityID].self, forKey: .allowedTools) ?? []
        )
        verificationRequest = try values.decodeIfPresent(
            VerificationRequest.self,
            forKey: .verificationRequest
        ) ?? .none
        verificationParameters = try values.decodeIfPresent(
            AgentVerificationParameters.self,
            forKey: .verificationParameters
        )
        budget = try values.decodeIfPresent(DelegationBudget.self, forKey: .budget) ?? .default

        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid agent task envelope: \(error.localizedDescription)",
                    underlyingError: error
                )
            )
        }
    }

    func validated() throws -> Self {
        try validate()
        return self
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AgentTaskContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try Self.requireContent(taskID, field: "taskID")
        try Self.requireContent(attemptID, field: "attemptID")
        try Self.requireContent(goal, field: "goal")
        guard !acceptanceCriteria.isEmpty else {
            throw AgentTaskContractError.missingAcceptanceCriteria
        }
        for criterion in acceptanceCriteria {
            try Self.requireContent(criterion, field: "acceptanceCriteria")
        }
        for path in suggestedScope {
            try Self.requireContent(path, field: "suggestedScope")
        }
        if verificationRequest == .none, verificationParameters != nil {
            throw AgentTaskContractError.verificationParametersWithoutRequest
        }
        try verificationParameters?.validate()
        _ = try budget.validated()
    }

    fileprivate static func requireContent(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskContractError.emptyField(field)
        }
    }

    private static func uniqued<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Terminal state reported by a worker/coordinator task exchange.
nonisolated enum AgentTaskOutcome: String, Codable, Sendable, Hashable {
    case completed
    case verified
    case cancelled
    case failed
}

/// Deterministic verification state. Generated prose cannot introduce another
/// state or directly claim that work is verified.
nonisolated enum AgentVerificationStatus: String, Codable, Sendable, Hashable {
    case notRequested = "not_requested"
    case passed
    case failed
    case cancelled
}

/// Receipt-linked verification evidence returned with a task result.
nonisolated struct AgentVerificationResult: Codable, Sendable, Hashable {
    let status: AgentVerificationStatus
    let receiptID: String?
    let detail: String?

    init(
        status: AgentVerificationStatus,
        receiptID: String? = nil,
        detail: String? = nil
    ) {
        self.status = status
        self.receiptID = receiptID
        self.detail = detail
    }
}

/// Machine-readable reason for a non-successful task result.
nonisolated enum AgentTaskFailureReason: String, Codable, Sendable, Hashable {
    case workerFailed = "worker_failed"
    case timedOut = "timed_out"
    case cancelled
    case toolNotAllowed = "tool_not_allowed"
    case pathOutsideScope = "path_outside_scope"
    case toolLimitReached = "tool_limit_reached"
    case revisionConflict = "revision_conflict"
    case verificationFailed = "verification_failed"
    case verificationInvalidated = "verification_invalidated"
    case invalidResult = "invalid_result"
}

/// Compact result returned without requiring transcript or Markdown parsing.
nonisolated struct AgentTaskResult: Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let taskID: String
    let attemptID: String
    let outcome: AgentTaskOutcome
    let technicalSummary: String
    let receiptIDs: [String]
    let verification: AgentVerificationResult
    let failureReason: AgentTaskFailureReason?
    let failureDetail: String?
    let unresolvedWork: [String]

    init(
        schemaVersion: Int = currentSchemaVersion,
        taskID: String,
        attemptID: String,
        outcome: AgentTaskOutcome,
        technicalSummary: String,
        receiptIDs: [String] = [],
        verification: AgentVerificationResult = .init(status: .notRequested),
        failureReason: AgentTaskFailureReason? = nil,
        failureDetail: String? = nil,
        unresolvedWork: [String] = []
    ) throws {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.attemptID = attemptID
        self.outcome = outcome
        self.technicalSummary = technicalSummary
        self.receiptIDs = Self.uniqued(receiptIDs)
        self.verification = verification
        self.failureReason = failureReason
        self.failureDetail = failureDetail
        self.unresolvedWork = unresolvedWork
        try validate()
    }

    /// Produces the one emergency result used when a caller bypasses envelope
    /// validation. Keeping this construction inside the type avoids force-try
    /// paths in the runtime while preserving a terminal, encodable outcome.
    static func invalidContractResult(taskID: String, attemptID: String) -> Self {
        Self(
            uncheckedTaskID: taskID.isEmpty ? "invalid-task" : taskID,
            attemptID: attemptID.isEmpty ? "invalid-attempt" : attemptID
        )
    }

    private init(uncheckedTaskID taskID: String, attemptID: String) {
        schemaVersion = Self.currentSchemaVersion
        self.taskID = taskID
        self.attemptID = attemptID
        outcome = .failed
        technicalSummary = "The task contract was invalid."
        receiptIDs = []
        verification = .init(status: .notRequested)
        failureReason = .invalidResult
        failureDetail = "The task contract was invalid."
        unresolvedWork = []
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        taskID = try values.decode(String.self, forKey: .taskID)
        attemptID = try values.decode(String.self, forKey: .attemptID)
        outcome = try values.decode(AgentTaskOutcome.self, forKey: .outcome)
        technicalSummary = try values.decode(String.self, forKey: .technicalSummary)
        receiptIDs = Self.uniqued(
            try values.decodeIfPresent([String].self, forKey: .receiptIDs) ?? []
        )
        verification = try values.decodeIfPresent(
            AgentVerificationResult.self,
            forKey: .verification
        ) ?? .init(status: .notRequested)
        failureReason = try values.decodeIfPresent(
            AgentTaskFailureReason.self,
            forKey: .failureReason
        )
        failureDetail = try values.decodeIfPresent(String.self, forKey: .failureDetail)
        unresolvedWork = try values.decodeIfPresent([String].self, forKey: .unresolvedWork) ?? []

        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid agent task result: \(error.localizedDescription)",
                    underlyingError: error
                )
            )
        }
    }

    func validated() throws -> Self {
        try validate()
        return self
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AgentTaskContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try Self.requireContent(taskID, field: "taskID")
        try Self.requireContent(attemptID, field: "attemptID")
        try Self.requireContent(technicalSummary, field: "technicalSummary")
        for receiptID in receiptIDs {
            try Self.requireContent(receiptID, field: "receiptIDs")
        }
        for item in unresolvedWork {
            try Self.requireContent(item, field: "unresolvedWork")
        }
        switch outcome {
        case .completed:
            guard verification.status == .notRequested,
                  failureReason == nil else {
                throw AgentTaskContractError.invalidTerminalState(.completed)
            }
        case .verified:
            guard verification.status == .passed,
                  failureReason == nil else {
                throw AgentTaskContractError.verifiedWithoutPassingVerification
            }
        case .failed:
            guard failureReason != nil else {
                throw AgentTaskContractError.missingFailureReason
            }
            guard verification.status != .passed else {
                throw AgentTaskContractError.invalidTerminalState(.failed)
            }
        case .cancelled:
            guard failureReason == .cancelled,
                  verification.status != .passed else {
                throw AgentTaskContractError.invalidTerminalState(.cancelled)
            }
        }
        if verification.status == .passed {
            guard let receiptID = verification.receiptID else {
                throw AgentTaskContractError.passingVerificationWithoutReceipt
            }
            try Self.requireContent(receiptID, field: "verification.receiptID")
        }
    }

    private static func requireContent(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentTaskContractError.emptyField(field)
        }
    }

    private static func uniqued<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Contract validation errors are stable enough for tests and adapter recovery,
/// while user-facing wording can still be localized at the presentation layer.
nonisolated enum AgentTaskContractError: LocalizedError, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case emptyField(String)
    case missingAcceptanceCriteria
    case invalidTimeout(Int)
    case invalidToolCallLimit(Int)
    case verificationParametersWithoutRequest
    case missingFailureReason
    case invalidTerminalState(AgentTaskOutcome)
    case verifiedWithoutPassingVerification
    case passingVerificationWithoutReceipt

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            "Unsupported agent task schema version \(version)."
        case .emptyField(let field):
            "\(field) must not be empty."
        case .missingAcceptanceCriteria:
            "At least one acceptance criterion is required."
        case .invalidTimeout(let seconds):
            "Delegation timeout must be positive, got \(seconds)."
        case .invalidToolCallLimit(let limit):
            "Maximum tool calls must not be negative, got \(limit)."
        case .verificationParametersWithoutRequest:
            "Verification parameters require a build or test request."
        case .missingFailureReason:
            "A failed task result requires a failure reason."
        case .invalidTerminalState(let outcome):
            "The \(outcome.rawValue) task result has inconsistent verification or failure evidence."
        case .verifiedWithoutPassingVerification:
            "A verified task result requires passing verification."
        case .passingVerificationWithoutReceipt:
            "Passing verification requires a receipt identifier."
        }
    }
}
