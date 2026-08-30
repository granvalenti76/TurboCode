import Foundation

/// Immutable receipt produced by a workspace-listing tool. It belongs to the
/// Core domain rather than SwiftUI so any host can persist or render it without
/// parsing model-facing text.
nonisolated public struct WorkspaceListingBlock: Codable, Hashable, Sendable {
    public let toolCallID: String
    public let path: String
    public let entries: [WorkspaceListingEntry]
    public let totalCount: Int
    public let isTruncated: Bool
    public let errorMessage: String?
    /// Presentation metadata is optional so sessions saved before the inspector
    /// existed continue to decode without a migration.
    public let capturedAt: Date?
    public let workspaceName: String?

    public init(
        toolCallID: String,
        path: String,
        entries: [WorkspaceListingEntry],
        totalCount: Int,
        isTruncated: Bool,
        errorMessage: String?,
        capturedAt: Date? = nil,
        workspaceName: String? = nil
    ) {
        self.toolCallID = toolCallID
        self.path = path
        self.entries = entries
        self.totalCount = totalCount
        self.isTruncated = isTruncated
        self.errorMessage = errorMessage
        self.capturedAt = capturedAt
        self.workspaceName = workspaceName
    }
}

nonisolated public struct WorkspaceListingEntry: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let relativePath: String
    public let kind: WorkspaceListingEntryKind
    public let sizeBytes: Int?
    public let modifiedAt: String?
    public let fileExtension: String?

    public var id: String { relativePath }
}

nonisolated public enum WorkspaceListingEntryKind: String, Codable, Hashable, Sendable {
    case directory
    case file
    case symbolicLink
}
