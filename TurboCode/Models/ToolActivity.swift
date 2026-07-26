import Foundation

/// A transient, user-visible description of one tool call in progress.
public struct ToolActivity: Identifiable, Sendable, Hashable {
    public let id: String
    public let summary: String
}
