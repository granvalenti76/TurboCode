import Foundation

/// Immutable presentation data for one destructive operation awaiting review.
nonisolated public struct ApprovalRequest: Sendable {
    public let id: String
    public let operation: String
    public let path: String
    public let destination: String?
    public let summary: String
    public let command: String?

    /// Produces a concise action label while retaining the model-provided
    /// summary as a fallback for operations unknown to this app version.
    public var displaySummary: String {
        let item = URL(fileURLWithPath: path).lastPathComponent
        if operation.hasPrefix("workspace.external.") {
            return "Allow access outside the active workspace?"
        }
        switch operation {
        case "createDirectory": return "Create \(item)"
        case "write": return "Write \(item)"
        case "append": return "Update \(item)"
        case "copy": return "Copy \(item)"
        case "move": return "Move \(item)"
        case "delete": return "Delete \(item)"
        case "removeFile": return "Delete \(item)"
        default: return summary
        }
    }

    public init(
        id: String,
        operation: String,
        path: String,
        destination: String? = nil,
        summary: String,
        command: String? = nil
    ) {
        self.id = id
        self.operation = operation
        self.path = path
        self.destination = destination
        self.summary = summary
        self.command = command
    }
}
