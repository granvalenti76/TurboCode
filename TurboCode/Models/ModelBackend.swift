import Foundation

/// The active inference backend shown by TurboCode's profile picker.
/// Codable and Hashable also let provider-neutral runtime requests retain the
/// selected backend without depending on a provider-specific session object.
public enum ModelBackend: String, CaseIterable, Codable, Hashable, Sendable {
    case llamaServer = "Llama-server"
    case foundationApple = "Foundation Apple"
    case foundationServe = "Apple PCC"
    case premium = "Premium"
    case codex = "Codex"
}

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
