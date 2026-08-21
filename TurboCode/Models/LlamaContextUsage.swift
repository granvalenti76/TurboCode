import Foundation

/// Runtime context occupancy reported by the active local Llama turn.
///
/// The server-provided context size is kept alongside the used token count so
/// the UI never compares a live measurement with a stale profile default.
nonisolated public struct LlamaContextUsage: Equatable, Sendable {
    public enum Level: String, Sendable {
        case low
        case medium
        case high
    }

    public let usedTokens: Int
    public let contextSize: Int

    public init(usedTokens: Int, contextSize: Int) {
        self.usedTokens = max(0, usedTokens)
        self.contextSize = max(1, contextSize)
    }

    public var fraction: Double {
        min(max(Double(usedTokens) / Double(contextSize), 0), 1)
    }

    public var percentage: Int {
        Int((fraction * 100).rounded())
    }

    public var level: Level {
        switch fraction {
        case ..<0.60:
            .low
        case ..<0.80:
            .medium
        default:
            .high
        }
    }
}
