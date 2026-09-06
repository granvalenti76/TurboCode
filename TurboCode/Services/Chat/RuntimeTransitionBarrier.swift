/// Settles runtime-owned work before an application context is replaced.
///
/// This is an ordered lifecycle protocol, not a lock: admission closes first,
/// profile handoffs and provider work unwind next, and admission reopens only
/// after every owner has released the old context.
@MainActor
final class RuntimeTransitionBarrier {
    private let runtime: AgentRuntime
    private let profiles: ProfileSelectionCoordinator
    private let checkpoint: @MainActor @Sendable () async -> Void

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
    func performContextChange<Result>(
        _ operation: @MainActor () async throws -> Result
    ) async rethrows -> Result {
        await runtime.beginQuiescence()
        await profiles.cancelAndWaitForTransitions()
        await runtime.cancelAndWaitForOperation()
        await checkpoint()
        do {
            let result = try await operation()
            await runtime.endQuiescence()
            return result
        } catch {
            await runtime.endQuiescence()
            throw error
        }
    }
}
