import Foundation

nonisolated enum WorkspaceAccessOperation: String, Sendable {
    case read
    case write
    case execute
    case destructive
}

nonisolated enum WorkspaceAccessGateError: LocalizedError, Sendable {
    case denied(String)
    case targetChanged

    var errorDescription: String? {
        switch self {
        case .denied(let path):
            "Access outside the active workspace was denied: \(path)"
        case .targetChanged:
            "The external target changed while authorization was pending."
        }
    }
}

/// One host-side protection ring shared by tools that need to cross the active
/// workspace. Grants are one-shot, bound to canonical inputs, and never derived
/// from model output.
actor WorkspaceAccessGate {
    static let shared = WorkspaceAccessGate()

    private static let granted = "TURBOCODE_HOST_ACCESS_GRANTED"

    func authorizeExternalExecution(
        tool: String,
        workspaceRoot: String,
        targetDescription: String,
        command: String? = nil,
        requestApproval: @Sendable (PendingToolApproval) async -> String = {
            await ToolApprovalRegistry.shared.request($0)
        }
    ) async -> Bool {
        let workspace = Self.canonical(URL(fileURLWithPath: workspaceRoot)).path
        let summary = "Allow \(tool) to access paths outside the active workspace?\nWorkspace: \(workspace)\nTarget: \(targetDescription)"
        let request = PendingToolApproval(
            id: UUID().uuidString,
            operation: "workspace.external.\(tool)",
            path: targetDescription,
            destination: nil,
            summary: summary,
            command: command,
            action: { Self.granted }
        )
        return await requestApproval(request) == Self.granted
    }

    nonisolated static func isInsideWorkspace(
        _ candidate: URL,
        workspaceRoot: String
    ) -> Bool {
        let root = canonical(URL(fileURLWithPath: workspaceRoot)).path
        let target = canonical(candidate).path
        return target == root || target.hasPrefix(root + "/")
    }

    nonisolated private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
