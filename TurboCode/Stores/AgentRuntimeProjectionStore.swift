import Observation

/// MainActor projection of immutable runtime state consumed by presentation.
///
/// This store is intentionally passive: it owns no reducer, task, provider, or
/// cancellation handle. Keeping Observation here lets the actor remain free of
/// UI dependencies and suitable for the future TurboCodeCore module boundary.
@MainActor
@Observable
final class AgentRuntimeProjectionStore {
    private(set) var snapshot: RuntimeSnapshot

    init(
        snapshot: RuntimeSnapshot = RuntimeSnapshot(
            backend: .foundationApple
        )
    ) {
        self.snapshot = snapshot
    }

    var hasActiveOperation: Bool {
        snapshot.hasActiveOperation
    }

    /// Replaces the complete projection in one observation transaction. Views
    /// never assemble lifecycle flags from independent mutable properties.
    func apply(_ snapshot: RuntimeSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }
}
