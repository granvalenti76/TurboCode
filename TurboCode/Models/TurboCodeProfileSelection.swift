import Foundation

/// Captures a destination while Codex prepares a context handoff.
///
/// Identifiers keep the asynchronous transition deterministic and avoid
/// retaining view closures inside either runtime store.
enum TurboCodeProfileSelection {
    case backend(ModelBackend)
    case remoteModel(String)
    case builtIn(ProfileBaseModelID)
    case dynamic(UUID)
}
