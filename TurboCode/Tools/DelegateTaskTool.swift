import Foundation
import FoundationModels

/// Minimal provider-facing choice for one delegated worker turn.
///
/// Runtime identifiers, safety timeout, and workspace confinement are owned by
/// TurboCode. Keeping them out of the model schema prevents coordinators from
/// inventing invalid policy values instead of describing the work itself.
@Generable
struct DelegateTaskArguments {
    /// Coarse worker mode: coding gets the configured tool bundle, text gets none.
    @Guide(.anyOf(["coding", "text"]))
    var mode: String = "coding"
    /// Concrete outcome the worker must produce.
    var goal: String
    /// Exact ID from the worker catalog; omit for automatic routing.
    var worker_id: String? = nil

    func envelope() throws -> AgentTaskEnvelope {
        guard let workerMode = DelegatedWorkerMode(rawValue: mode) else {
            throw DelegateTaskAdapterError.unknownMode(mode)
        }
        let taskID = UUID().uuidString
        return try AgentTaskEnvelope(
            taskID: taskID,
            attemptID: "\(taskID)-attempt-1",
            mode: workerMode,
            goal: goal,
            acceptanceCriteria: ["Complete the delegated goal and report the result."],
            // The worker may use any workspace path its registered tools allow.
            // Per-path restrictions belong in a future explicit UI, not in
            // coordinator-authored prose masquerading as policy.
            suggestedScope: [],
            verificationRequest: .none,
            budget: .default,
            workerID: worker_id
        )
    }
}

nonisolated enum DelegateTaskAdapterError: LocalizedError, Sendable, Equatable {
    case unknownMode(String)

    var errorDescription: String? {
        switch self {
        case .unknownMode(let mode):
            "Unknown delegated worker mode '\(mode)'."
        }
    }
}

/// Profile-owned routing facts shared by native and Codex coordinators.
nonisolated struct AgentTaskWorkerDescriptor: Codable, Sendable, Hashable {
    let id: String
    let name: String
    let model: String
    let roleDescription: String?
    let toolNames: [String]
}

nonisolated enum AgentTaskRoutingError: LocalizedError, Sendable {
    case unknownWorker(String)
    case workerBusy(String)

    var errorDescription: String? {
        switch self {
        case .unknownWorker(let id): "Unknown worker_id '\(id)'. Choose an ID from the worker catalog."
        case .workerBusy(let id): "Worker '\(id)' is busy. No other worker was substituted. Retry after its completion."
        }
    }

    func result(for envelope: AgentTaskEnvelope) -> AgentTaskResult {
        (try? AgentTaskResult(
            taskID: envelope.taskID, attemptID: envelope.attemptID,
            outcome: .failed, technicalSummary: errorDescription ?? "Worker routing failed.",
            failureReason: .workerFailed, failureDetail: errorDescription,
            workerID: envelope.workerID
        )) ?? .invalidContractResult(taskID: envelope.taskID, attemptID: envelope.attemptID)
    }
}

/// Provider-neutral worker invocation used by both coordinator adapters.
nonisolated protocol AgentTaskInvoking: Sendable {
    /// Admission capacity promised by this invocation graph. Provider
    /// endpoints are not probed; profile worker slots are the authority.
    var maximumConcurrentTasks: Int { get }
    var workerCatalog: [AgentTaskWorkerDescriptor] { get }

    @MainActor
    func invoke(_ envelope: AgentTaskEnvelope) async -> AgentTaskResult
}

nonisolated extension AgentTaskInvoking {
    var maximumConcurrentTasks: Int { 1 }
    var workerCatalog: [AgentTaskWorkerDescriptor] { [] }

    func validateDestination(_ workerID: String?) throws {
        if let workerID, !workerCatalog.contains(where: { $0.id == workerID }) {
            throw AgentTaskRoutingError.unknownWorker(workerID)
        }
    }
}

/// Optional extension of the invocation boundary for adapters that can carry
/// the owning application turn into a worker envelope. Keeping this separate
/// preserves older test and provider invokers while the harness migrates them.
nonisolated protocol TurnAwareAgentTaskInvoking: AgentTaskInvoking {
    @MainActor
    func invoke(
        _ envelope: AgentTaskEnvelope,
        parentTurnID: TurnID?
    ) async -> AgentTaskResult
}

/// A configured invocation graph that can detach parent-turn callbacks while
/// retaining its immutable worker sessions for background delivery.
nonisolated protocol BackgroundIsolatableAgentTaskInvoking: AgentTaskInvoking {
    func backgroundIsolated(
        toolFinished: @escaping @Sendable (AgentTaskToolOutputEvent) async -> Void
    ) -> any AgentTaskInvoking
}

nonisolated enum AgentTaskInvocation {
    @MainActor
    static func invoke(
        _ invoker: any AgentTaskInvoking,
        envelope: AgentTaskEnvelope,
        parentTurnID: TurnID?
    ) async -> AgentTaskResult {
        if let turnAware = invoker as? any TurnAwareAgentTaskInvoking {
            return await turnAware.invoke(
                envelope,
                parentTurnID: parentTurnID
            )
        }
        return await invoker.invoke(envelope)
    }
}

/// Stable acknowledgement returned when the harness retains a delegated task
/// after the invoking model turn is free to settle.
nonisolated struct DelegatedTaskReceipt: Codable, Sendable, Hashable {
    let status: String
    let taskID: String
    let attemptID: String
    /// Requested destination; actual executor is included in the terminal result.
    let workerID: String?

    init(envelope: AgentTaskEnvelope) {
        status = "accepted"
        taskID = envelope.taskID
        attemptID = envelope.attemptID
        workerID = envelope.workerID
    }
}

/// Application-owned admission port shared by Foundation Models, Codex, and
/// the explicit `/task` command. The invoker remains immutable worker context;
/// the receiver decides how to retain and surface its asynchronous lifetime.
typealias DelegatedTaskBackgroundSubmission = @Sendable (
    _ envelope: AgentTaskEnvelope,
    _ invoker: any AgentTaskInvoking,
    _ parentTurnID: TurnID?
) async throws -> DelegatedTaskReceipt

nonisolated enum DelegatedTaskSupervisorError: LocalizedError, Sendable {
    case workerAlreadyRunning
    case workerPoolAtCapacity(Int)
    case missingOriginatingConversation

    var errorDescription: String? {
        switch self {
        case .workerAlreadyRunning:
            "This delegated task is already running in the background."
        case .workerPoolAtCapacity(let capacity):
            "All \(capacity) configured worker slots are currently busy."
        case .missingOriginatingConversation:
            "TurboCode could not identify the originating conversation."
        }
    }
}

/// Retains background work independently from the conversational runtime.
/// Actual concurrency is bounded by the configured worker pool; this actor
/// owns lifetimes and cancellation rather than provider capacity.
actor DelegatedTaskSupervisor {
    typealias Completion = @Sendable (AgentTaskResult) async -> Void

    private var operations: [String: Task<Void, Never>] = [:]

    func submit(
        envelope: AgentTaskEnvelope,
        invoker: any AgentTaskInvoking,
        parentTurnID: TurnID?,
        completion: @escaping Completion
    ) throws -> DelegatedTaskReceipt {
        let identity = "\(envelope.taskID):\(envelope.attemptID)"
        guard operations[identity] == nil else {
            throw DelegatedTaskSupervisorError.workerAlreadyRunning
        }
        let capacity = max(1, invoker.maximumConcurrentTasks)
        guard operations.count < capacity else {
            throw DelegatedTaskSupervisorError.workerPoolAtCapacity(capacity)
        }

        operations[identity] = Task { [weak self] in
            let result = await AgentTaskInvocation.invoke(
                invoker,
                envelope: envelope,
                parentTurnID: parentTurnID
            )
            await completion(result)
            await self?.settle(identity: identity)
        }
        return DelegatedTaskReceipt(envelope: envelope)
    }

    func cancel() {
        for operation in operations.values {
            operation.cancel()
        }
    }

    @discardableResult
    func cancel(taskID: String, attemptID: String) -> Bool {
        guard let operation = operations["\(taskID):\(attemptID)"] else {
            return false
        }
        operation.cancel()
        return true
    }

    private func settle(identity: String) {
        operations[identity] = nil
    }
}

/// Binds a routed worker context to the bounded task runner.
nonisolated struct ConfiguredAgentTaskInvoker: TurnAwareAgentTaskInvoking,
    BackgroundIsolatableAgentTaskInvoking {
    let runner: any AgentTaskRunning
    let context: AgentTaskRunContext
    let events: AgentTaskRunnerEvents
    let coordinator: AgentActivityAgent?
    let worker: AgentActivityAgent?
    let descriptor: AgentTaskWorkerDescriptor?
    var workerCatalog: [AgentTaskWorkerDescriptor] { descriptor.map { [$0] } ?? [] }
    let activityChanged: @Sendable (AgentActivityRuntimeEvent) async -> Void

    init(
        runner: any AgentTaskRunning,
        context: AgentTaskRunContext,
        events: AgentTaskRunnerEvents,
        coordinator: AgentActivityAgent? = nil,
        worker: AgentActivityAgent? = nil,
        descriptor: AgentTaskWorkerDescriptor? = nil,
        activityChanged: @escaping @Sendable (
            AgentActivityRuntimeEvent
        ) async -> Void = { _ in }
    ) {
        self.runner = runner
        self.context = context
        self.events = events
        self.coordinator = coordinator
        self.worker = worker
        self.descriptor = descriptor
        self.activityChanged = activityChanged
    }

    /// Detaches a retained worker from its parent turn's transient Activity and
    /// tool callbacks. The background harness supplies durable callbacks whose
    /// output can be routed by originating conversation after the turn ends.
    func backgroundIsolated(
        toolFinished: @escaping @Sendable (
            AgentTaskToolOutputEvent
        ) async -> Void
    ) -> any AgentTaskInvoking {
        isolatedCopy(toolFinished: toolFinished)
    }

    func isolatedCopy(
        toolFinished: @escaping @Sendable (
            AgentTaskToolOutputEvent
        ) async -> Void
    ) -> Self {
        Self(
            runner: runner,
            context: context,
            events: AgentTaskRunnerEvents(toolFinished: toolFinished),
            coordinator: coordinator,
            worker: worker,
            descriptor: descriptor,
            activityChanged: activityChanged
        )
    }

    @MainActor
    func invoke(_ envelope: AgentTaskEnvelope) async -> AgentTaskResult {
        return await invoke(envelope, parentTurnID: envelope.parentTurnID)
    }

    @MainActor
    func invoke(
        _ envelope: AgentTaskEnvelope,
        parentTurnID: TurnID?
    ) async -> AgentTaskResult {
        if let workerID = envelope.workerID, descriptor?.id != workerID {
            return AgentTaskRoutingError.unknownWorker(workerID).result(for: envelope)
        }
        let scopedEnvelope = (try? envelope.withParentTurnID(
            parentTurnID ?? envelope.parentTurnID
        )) ?? envelope
        if let coordinator, let worker {
            await activityChanged(
                .started(
                    envelope: scopedEnvelope,
                    coordinator: coordinator,
                    worker: worker,
                    startedAt: .now
                )
            )
            await activityChanged(
                .phaseChanged(
                    taskID: scopedEnvelope.taskID,
                    attemptID: scopedEnvelope.attemptID,
                    phase: .delegating
                )
            )
            // The bounded runner owns the complete worker session, so entering
            // it is the deterministic handoff boundary.
            await activityChanged(
                .phaseChanged(
                    taskID: scopedEnvelope.taskID,
                    attemptID: scopedEnvelope.attemptID,
                    phase: .workerRunning
                )
            )
        }

        let result = await runner.run(
            envelope: scopedEnvelope,
            context: context,
            events: events
        ).attributed(to: descriptor)
        if coordinator != nil, worker != nil {
            // Every runner path returns a typed terminal result, including
            // timeout and cancellation, which also closes any active tool.
            await activityChanged(.finished(result))
        }
        return result
    }
}

/// Fair lease manager for independently configured worker slots. A repeated
/// Llama worker therefore becomes a real concurrent request slot rather than
/// a decorative profile row. Automatic calls wait for a free slot; explicit
/// destinations fail when busy, preserving the coordinator's routing choice.
actor AgentTaskWorkerPool {
    nonisolated struct Lease: Sendable {
        let index: Int
        let invoker: ConfiguredAgentTaskInvoker
    }

    private let invokers: [ConfiguredAgentTaskInvoker]
    private var available: [Int]
    private var waiters: [CheckedContinuation<Lease, Never>] = []

    init(invokers: [ConfiguredAgentTaskInvoker]) {
        self.invokers = invokers
        available = Array(invokers.indices)
    }

    func acquire(workerID: String? = nil) async throws -> Lease {
        if let workerID {
            guard let index = invokers.firstIndex(where: { $0.descriptor?.id == workerID }) else {
                throw AgentTaskRoutingError.unknownWorker(workerID)
            }
            guard let position = available.firstIndex(of: index) else {
                throw AgentTaskRoutingError.workerBusy(workerID)
            }
            available.remove(at: position)
            return Lease(index: index, invoker: invokers[index])
        }
        if let index = available.first {
            available.removeFirst()
            return Lease(index: index, invoker: invokers[index])
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release(_ lease: Lease) {
        if waiters.isEmpty {
            available.append(lease.index)
        } else {
            let continuation = waiters.removeFirst()
            continuation.resume(returning: lease)
        }
    }
}

/// Routes each delegated call to one free configured slot while preserving the
/// existing provider-neutral invocation contract used by `/task` and tools.
nonisolated struct ConfiguredAgentTaskPoolInvoker: TurnAwareAgentTaskInvoking,
    BackgroundIsolatableAgentTaskInvoking {
    let invokers: [ConfiguredAgentTaskInvoker]
    private let pool: AgentTaskWorkerPool

    init(invokers: [ConfiguredAgentTaskInvoker]) {
        precondition(!invokers.isEmpty)
        self.invokers = invokers
        pool = AgentTaskWorkerPool(invokers: invokers)
    }

    var maximumConcurrentTasks: Int { invokers.count }
    var workerCatalog: [AgentTaskWorkerDescriptor] { invokers.flatMap(\.workerCatalog) }

    @MainActor
    func invoke(_ envelope: AgentTaskEnvelope) async -> AgentTaskResult {
        await invoke(envelope, parentTurnID: envelope.parentTurnID)
    }

    @MainActor
    func invoke(
        _ envelope: AgentTaskEnvelope,
        parentTurnID: TurnID?
    ) async -> AgentTaskResult {
        let lease: AgentTaskWorkerPool.Lease
        do {
            lease = try await pool.acquire(workerID: envelope.workerID)
        } catch let error as AgentTaskRoutingError {
            return error.result(for: envelope)
        } catch {
            return .invalidContractResult(taskID: envelope.taskID, attemptID: envelope.attemptID)
        }
        let result = await lease.invoker.invoke(
            envelope,
            parentTurnID: parentTurnID
        )
        await pool.release(lease)
        return result
    }

    func backgroundIsolated(
        toolFinished: @escaping @Sendable (
            AgentTaskToolOutputEvent
        ) async -> Void
    ) -> any AgentTaskInvoking {
        BackgroundPooledAgentTaskInvoker(
            pool: pool,
            maximumConcurrentTasks: maximumConcurrentTasks,
            workerCatalog: workerCatalog,
            toolFinished: toolFinished
        )
    }
}

/// Per-submission journal wrapper over the shared pool. The lease remains
/// global to the profile while tool receipts are isolated by originating task.
nonisolated struct BackgroundPooledAgentTaskInvoker: TurnAwareAgentTaskInvoking {
    let pool: AgentTaskWorkerPool
    let maximumConcurrentTasks: Int
    let workerCatalog: [AgentTaskWorkerDescriptor]
    let toolFinished: @Sendable (AgentTaskToolOutputEvent) async -> Void

    @MainActor
    func invoke(_ envelope: AgentTaskEnvelope) async -> AgentTaskResult {
        await invoke(envelope, parentTurnID: envelope.parentTurnID)
    }

    @MainActor
    func invoke(
        _ envelope: AgentTaskEnvelope,
        parentTurnID: TurnID?
    ) async -> AgentTaskResult {
        let lease: AgentTaskWorkerPool.Lease
        do {
            lease = try await pool.acquire(workerID: envelope.workerID)
        } catch let error as AgentTaskRoutingError {
            return error.result(for: envelope)
        } catch {
            return .invalidContractResult(taskID: envelope.taskID, attemptID: envelope.attemptID)
        }
        let isolated = lease.invoker.isolatedCopy(toolFinished: toolFinished)
        let result = await isolated.invoke(
            envelope,
            parentTurnID: parentTurnID
        )
        await pool.release(lease)
        return result
    }
}

/// Structured coordinator tool used by production Foundation Models profiles,
/// including DeepSeek's OpenAI-compatible transport.
struct DelegateTaskTool: Tool {
    typealias Arguments = DelegateTaskArguments
    typealias Output = String

    let invoker: any AgentTaskInvoking
    let currentTurnID: @MainActor @Sendable () async -> TurnID?
    let backgroundSubmission: DelegatedTaskBackgroundSubmission?

    init(
        invoker: any AgentTaskInvoking,
        currentTurnID: @escaping @MainActor @Sendable () async -> TurnID? = { nil },
        backgroundSubmission: DelegatedTaskBackgroundSubmission? = nil
    ) {
        self.invoker = invoker
        self.currentTurnID = currentTurnID
        self.backgroundSubmission = backgroundSubmission
    }

    var name: String { "delegate_task" }
    var description: String {
        let capacityGuidance = if invoker.maximumConcurrentTasks > 1 {
            """
            This profile has \(invoker.maximumConcurrentTasks) worker slots. When background
            delegation is enabled, independent goals may be submitted separately and run
            concurrently. Keep their file scopes disjoint and never run concurrent Git
            mutations; overlapping writes can conflict. Calls above capacity are rejected.
            """
        } else {
            "This profile has one worker slot, so only one delegated task may run at a time."
        }
        return """
        Delegate one goal. Set worker_id to an exact catalog ID to select a worker,
        or omit it for the first free slot. A busy target is not replaced. Use coding when the worker
        must inspect or change the workspace: it receives the complete worker
        tool bundle configured by the active profile. Use text when the worker only needs to
        return prose: it receives no tools.
        \(capacityGuidance)
        TurboCode returns either a JSON AgentTaskResult or an accepted receipt
        when background delegation is enabled. Do not wait or poll after an
        accepted receipt; the harness reports the result when the worker ends.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: DelegateTaskArguments) async throws -> String {
        let envelope = try arguments.envelope()
        try invoker.validateDestination(envelope.workerID)
        let parentTurnID = await currentTurnID()
        if let backgroundSubmission {
            let receipt = try await backgroundSubmission(
                envelope,
                invoker,
                parentTurnID
            )
            return try Self.encode(receipt)
        }
        let result = await AgentTaskInvocation.invoke(
            invoker,
            envelope: envelope,
            parentTurnID: parentTurnID
        )
        return try Self.encode(result)
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentTaskWorkerError.invalidEnvelopeEncoding
        }
        return json
    }
}
