import Foundation

/// Captures a destination while Codex prepares a context handoff.
///
/// Identifiers keep the asynchronous transition deterministic and avoid
/// retaining view closures inside either runtime store.
enum TurboCodeProfileSelection {
    case backend(ModelBackend)
    case remoteModel(String)
    // Carry effort through the asynchronous handoff and apply it only when
    // the destination becomes active, before its single session rebuild.
    case builtIn(ProfileBaseModelID, reasoning: ReasoningEffort? = nil)
    case dynamic(UUID)
}
