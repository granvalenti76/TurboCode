import Foundation

/// Stable identity for the inference backend selected by a TurboCode host.
///
/// The core stores only this serializable identity. Provider clients, endpoint
/// configuration, credentials, and concrete sessions remain dependencies of
/// the application composition root and never cross the domain boundary.
public enum ModelBackend: String, CaseIterable, Codable, Hashable, Sendable {
    case llamaServer = "Llama-server"
    case foundationApple = "Foundation Apple"
    // PCC-RETIREMENT: remove the legacy backend identity with `fm serve` support.
    case foundationServe = "Apple PCC"
    case premium = "Premium"
    case codex = "Codex"
}
