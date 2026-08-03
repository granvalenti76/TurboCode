import Foundation

/// Stable roles shown by Activity and used to constrain model capabilities.
nonisolated enum AgentModelRole: String, Codable, Sendable, Hashable {
    case microtaskOnDevice = "microtask_on_device"
    case codingWorker = "coding_worker"
    case powerfulCoordinator = "powerful_coordinator"
    case experimentalOnDeviceCoordinator = "experimental_on_device_coordinator"
}

/// A route selected from explicit profile/runtime state, never from a model's
/// subjective assessment of the user's prompt.
nonisolated struct ModelRoutingDecision: Sendable, Hashable {
    let role: AgentModelRole
    let profile: ModelRuntimeProfile
    let supportsStructuredDelegation: Bool
}

/// Deterministic 0.2.0 routing policy.
///
/// The user-selected profile is authoritative: TurboCode does not ask the
/// on-device model to decide whether a task deserves a stronger model.
nonisolated enum ModelRoutingPolicy {
    static func resolve(
        backend: ModelBackend,
        mode: OrchestratorMode,
        activeProfile: UserDynamicProfile?
    ) -> ModelRoutingDecision {
        if mode == .orchestrator {
            return ModelRoutingDecision(
                role: .experimentalOnDeviceCoordinator,
                profile: .orchestrator,
                supportsStructuredDelegation: false
            )
        }
        if backend != .foundationApple,
           activeProfile?.resolvedToolIDs.contains(.delegateTask) == true {
            return ModelRoutingDecision(
                role: .powerfulCoordinator,
                profile: .standalone,
                supportsStructuredDelegation: true
            )
        }
        if backend == .foundationApple {
            return ModelRoutingDecision(
                role: .microtaskOnDevice,
                profile: .microtask,
                supportsStructuredDelegation: false
            )
        }
        return ModelRoutingDecision(
            role: .codingWorker,
            profile: .standalone,
            supportsStructuredDelegation: false
        )
    }
}
