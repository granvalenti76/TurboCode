import Foundation

// MARK: - OrchestratorMode

/// Controls how the AI models are used for inference.
///
/// - ``standalone``: The user picks a single backend (e.g. Llama or Apple on-device).
///   The chosen model handles the entire conversation. This is the legacy behaviour.
/// - ``orchestrator``: Experimental compatibility path where Apple on-device
///   delegates free-text work through `call_powerful_model`. The structured
///   0.2.0 release path uses a powerful coordinator profile instead.
nonisolated public enum OrchestratorMode: String, CaseIterable, Sendable {
    case standalone = "Standalone"
    case orchestrator = "Orchestrator"

    var displayName: String {
        switch self {
        case .standalone: "Standalone"
        case .orchestrator: "On-Device (Experimental)"
        }
    }
}
