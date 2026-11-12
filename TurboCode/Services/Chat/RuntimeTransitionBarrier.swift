/// Settles runtime-owned work before an application context is replaced.
///
/// This is an ordered lifecycle protocol: admission closes first, profile
/// handoffs and provider work unwind next, and admission reopens only after
/// every owner has released the old context.
///
/// Context changes are also serialized. Each sidebar click or workspace switch
/// arrives as its own unstructured task, and a replacement suspends many times
/// while the thread identity, the visible timeline, and the provider session
/// are swapped one after another. Two interleaved replacements used to let the
/// second one checkpoint that half-installed state, saving one conversation's
/// file with another conversation's blocks or transcript. The FIFO turn below
/// guarantees a checkpoint only ever observes a fully installed context.
@MainActor
final class RuntimeTransitionBarrier {
    private let runtime: AgentRuntime
    private let profiles: ProfileSelectionCoordinator
    private let checkpoint: @MainActor @Sendable () async -> Void

    /// True while one context change owns the turn, from its settling phase
    /// until its operation has returned.
    private var isTurnHeld = false
    /// Later context changes, resumed strictly in arrival order. The turn is
    /// handed over directly, so no newcomer can overtake a queued change.
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []

    /// True only while a replacement operation is running, when the thread
    /// identity, timeline, and provider session may belong to different
    /// conversations. Session saves must not snapshot that mixed state.
    private(set) var isChangingContext = false
    /// Advances each time a replacement operation starts. A save that began
    /// before a context change and resumes after it compares this value to
    /// detect that its captured state straddles two contexts.
    private(set) var contextGeneration: UInt64 = 0

    init(
        runtime: AgentRuntime,
        profiles: ProfileSelectionCoordinator,
        checkpoint: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.runtime = runtime
        self.profiles = profiles
        self.checkpoint = checkpoint
    }

    /// Runs one complete context replacement while admission is closed. The
    /// balanced release on both success and failure prevents a transition from
    /// either admitting work midway or leaving the runtime permanently closed.
    ///
    /// The operation must not start another context change: it would wait for
    /// the turn its own caller is holding.
    func performContextChange<Result>(
        _ operation: @MainActor () async throws -> Result
    ) async rethrows -> Result {
        // Close admission before queueing. The quiescence depth then stays
        // above zero across the handoff between two queued changes, so no
        // message can be admitted into the gap between them.
        await runtime.beginQuiescence()
        await acquireTurn()
        await profiles.cancelAndWaitForTransitions()
        await runtime.cancelAndWaitForOperation()
        await checkpoint()
        isChangingContext = true
        contextGeneration &+= 1
        do {
            let result = try await operation()
            isChangingContext = false
            releaseTurn()
            await runtime.endQuiescence()
            return result
        } catch {
            isChangingContext = false
            releaseTurn()
            await runtime.endQuiescence()
            throw error
        }
    }

    /// Deliberately not cancellable: a context change abandoned while queued
    /// or midway would leave the application in exactly the mixed state this
    /// barrier exists to prevent.
    private func acquireTurn() async {
        guard isTurnHeld else {
            isTurnHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            turnWaiters.append(continuation)
        }
    }

    private func releaseTurn() {
        guard !turnWaiters.isEmpty else {
            isTurnHeld = false
            return
        }
        // Ownership passes to the next waiter without clearing `isTurnHeld`.
        turnWaiters.removeFirst().resume()
    }
}
