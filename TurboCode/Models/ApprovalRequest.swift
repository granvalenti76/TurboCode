import Foundation

/// Immutable presentation data for one host-owned operation awaiting review.
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
            let components = operation.split(separator: ".")
            let tool = components.count > 2
                ? components[2].replacingOccurrences(of: "_", with: " ")
                : "tool"
            let action = components.count > 3 ? String(components[3]) : "access"
            return "Allow \(tool) to \(action) outside the active workspace?"
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

    /// Structured filesystem tools expose their exact canonical targets in the
    /// approval UI. Bash presents the exact command instead because its paths
    /// are discovered by the operating-system sandbox at execution time.
    public var externalTargetDetails: String? {
        guard operation.hasPrefix("workspace.external."), command == nil else {
            return nil
        }
        return [path, destination].compactMap { $0 }.joined(separator: "\n")
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
