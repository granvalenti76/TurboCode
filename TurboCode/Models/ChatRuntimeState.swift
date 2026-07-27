import Foundation

/// High-level availability reported by the active chat runtime.
public enum RuntimeStatus: String, Sendable, Hashable {
    case disconnected
    case connecting
    case ready
    case error
}

/// Connection lifecycle exposed to runtime-related presentation components.
public enum RuntimeConnectionState: String, Sendable, Hashable {
    case disconnected
    case connecting
    case ready
}
