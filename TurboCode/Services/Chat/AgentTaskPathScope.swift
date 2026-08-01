import Foundation

/// Resolves task-declared paths against the workspace and enforces the narrowest
/// boundary shared by runner preflight and concrete file tools.
nonisolated struct AgentTaskPathScope: Sendable, Hashable {
    let workspaceRoot: String
    let suggestedPaths: [String]

    /// An empty task scope intentionally inherits the existing workspace-wide
    /// policy. A non-empty scope allows an exact path or any descendant.
    func validate(_ requestedPath: String) throws {
        guard !suggestedPaths.isEmpty else { return }
        let requestedURL = try WorkspacePathResolver.resolve(
            requestedPath,
            within: workspaceRoot
        )
        let requested = requestedURL.standardizedFileURL.path
        let allowed = try suggestedPaths.contains { scopePath in
            let scopeURL = try WorkspacePathResolver.resolve(
                scopePath,
                within: workspaceRoot
            )
            let scope = scopeURL.standardizedFileURL.path
            return requested == scope || requested.hasPrefix(scope + "/")
        }
        guard allowed else {
            throw AgentTaskPathScopeError.outsideDeclaredScope(
                path: requestedPath,
                scope: suggestedPaths
            )
        }
    }
}

nonisolated enum AgentTaskPathScopeError: LocalizedError, Sendable, Equatable {
    case outsideDeclaredScope(path: String, scope: [String])

    var errorDescription: String? {
        switch self {
        case .outsideDeclaredScope(let path, let scope):
            "Path '\(path)' is outside the delegated task scope: \(scope.joined(separator: ", "))."
        }
    }
}
