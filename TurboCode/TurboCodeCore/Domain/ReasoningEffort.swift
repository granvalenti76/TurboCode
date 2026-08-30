/// Provider-neutral reasoning intensity selected by the user.
///
/// The raw values are persisted by the composer. Keep them stable so moving
/// this contract out of SwiftUI never resets an existing preference.
nonisolated enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}
