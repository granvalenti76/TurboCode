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

    /// Stable compact copy for the composer hover helper. Keeping this format
    /// in the value type prevents the view from silently changing the user
    /// facing contract while still allowing accessibility to use fuller prose.
    public var tooltipText: String {
        "\(percentage)% (\(usedTokens)/\(contextSize))"
    }

    /// Full spoken value for VoiceOver; the visual helper intentionally stays
    /// compact and does not repeat the provider name.
    public var accessibilityText: String {
        "\(percentage) percent, \(usedTokens) of \(contextSize) tokens"
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
