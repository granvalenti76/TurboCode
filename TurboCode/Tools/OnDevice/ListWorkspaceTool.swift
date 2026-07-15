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

/// Flat, read-only directory listing designed to be reliable for smaller models.
struct ListWorkspaceTool: Tool {
    typealias Arguments = ListWorkspaceArguments
    typealias Output = WorkspaceListingToolOutput

    let workspaceRoot: String

    var name: String { "list_workspace" }
    var description: String {
        """
        List one directory inside the active workspace. Use this instead of
        file_system when the user asks to browse, inspect, or show files and
        folders. Pass only a workspace-relative directory path; use "." for the
        root. This tool is read-only and returns structured file metadata.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: ListWorkspaceArguments) async throws -> WorkspaceListingToolOutput {
        do {
            let snapshot = try WorkspaceBrowsingService(workspaceRoot: workspaceRoot)
                .listDirectory(at: arguments.path)
            let formatter = ISO8601DateFormatter()
            return WorkspaceListingToolOutput(
                path: snapshot.relativePath,
                entries: snapshot.entries.map { entry in
                    WorkspaceListingToolEntry(
                        name: entry.name,
                        relativePath: entry.relativePath,
                        kind: entry.kind.rawValue,
                        sizeBytes: entry.sizeBytes,
                        modifiedAt: entry.modifiedAt.map(formatter.string(from:)),
                        fileExtension: entry.fileExtension
                    )
                },
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
