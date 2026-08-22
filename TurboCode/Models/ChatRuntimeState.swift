import Foundation

/// High-level availability reported by the active chat runtime.
public enum RuntimeStatus: String, Sendable, Hashable {
    case disconnected
    case connecting
    case ready
    case error
}
