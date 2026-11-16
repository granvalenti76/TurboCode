/// Provider-neutral reasoning intensity selected by the user.
///
/// The raw values are persisted by the composer. Keep them stable so moving
/// this contract out of SwiftUI never resets an existing preference.
nonisolated enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case xhigh = "X-High"
}

nonisolated extension ReasoningEffort {
    /// Spelling used by chat templates that accept `reasoning_effort`. Kept
    /// separate from `rawValue`, which is a persisted UI preference.
    var serverLevelName: String {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .xhigh: "xhigh"
        }
    }
}
