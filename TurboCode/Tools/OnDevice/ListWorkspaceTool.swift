import Foundation
import FoundationModels

@Generable
struct ListWorkspaceArguments {
    /// Workspace-relative directory to inspect. Use "." for the workspace root.
    var path: String
}

@Generable
struct WorkspaceListingToolEntry {
    var name: String
    var relativePath: String
    var kind: String
    var sizeBytes: Int?
    var modifiedAt: String?
    var fileExtension: String?
}

@Generable
struct WorkspaceListingToolOutput {
    var path: String
    var entries: [WorkspaceListingToolEntry]
    var totalCount: Int
    var isTruncated: Bool
    var errorMessage: String?
}

/// Flat, read-only directory listing that reports facts without prescribing the
/// model's next exploration step.
struct ListWorkspaceTool: Tool {
    typealias Arguments = ListWorkspaceArguments
    typealias Output = WorkspaceListingToolOutput

    let workspaceRoot: String
    let taskScope: AgentTaskPathScope?

    init(
        workspaceRoot: String,
        taskScope: AgentTaskPathScope? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.taskScope = taskScope
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(
            workspaceRoot: workspaceRoot,
            taskScope: scope
        )
    }

    var name: String { "list_workspace" }
    var description: String {
        """
        List one directory in the active workspace. Pass a workspace-relative
        path; use "." for the root. The result is read-only and shown natively,
        so do not repeat its entries unless the user asks for analysis.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: ListWorkspaceArguments) async throws -> WorkspaceListingToolOutput {
        if let taskScope {
            do {
                try taskScope.validate(arguments.path)
            } catch {
                return WorkspaceListingToolOutput(
                    path: arguments.path,
                    entries: [],
                    totalCount: 0,
                    isTruncated: false,
                    errorMessage: error.localizedDescription
                )
            }
        }
        do {
            let snapshot = try WorkspaceBrowsingService(workspaceRoot: workspaceRoot)
                .listDirectory(at: arguments.path)
            let formatter = ISO8601DateFormatter()
            let entries = snapshot.entries.map { entry in
                WorkspaceListingToolEntry(
                    name: entry.name,
                    relativePath: entry.relativePath,
                    kind: entry.kind.rawValue,
                    sizeBytes: entry.sizeBytes,
                    modifiedAt: entry.modifiedAt.map(formatter.string(from:)),
                    fileExtension: entry.fileExtension
                )
            }
            return WorkspaceListingToolOutput(
                path: snapshot.relativePath,
                entries: entries,
                totalCount: snapshot.totalCount,
                isTruncated: snapshot.isTruncated,
                errorMessage: nil
            )
        } catch {
            return WorkspaceListingToolOutput(
                path: arguments.path,
                entries: [],
                totalCount: 0,
                isTruncated: false,
                errorMessage: error.localizedDescription
            )
        }
    }
}
