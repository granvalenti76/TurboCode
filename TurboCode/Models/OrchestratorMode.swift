import Foundation

// MARK: - OrchestratorMode

/// Controls how the AI models are used for inference.
///
/// - ``standalone``: The user picks a single backend (e.g. Llama or Apple on-device).
///   The chosen model handles the entire conversation. This is the legacy behaviour.
/// - ``orchestrator``: The Apple on-device model acts as orchestrator.
///   It receives every user message and may delegate complex tasks to a powerful
///   model (e.g. Llama) via a tool call, then synthesises the final response.
public enum OrchestratorMode: String, CaseIterable, Sendable {
    case standalone = "Standalone"
    case orchestrator = "Orchestrator"
}
