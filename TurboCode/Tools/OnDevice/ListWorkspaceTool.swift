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
    /// Optional model-only direction appended for runtimes that need help
    /// continuing from a broad listing. Native presentation ignores it.
    var modelGuidance: String?
}

/// Flat, read-only directory listing designed to be reliable for smaller models.
struct ListWorkspaceTool: Tool {
    typealias Arguments = ListWorkspaceArguments
    typealias Output = WorkspaceListingToolOutput

    let workspaceRoot: String
    let suggestsXcodeAnalysisTools: Bool
    let taskScope: AgentTaskPathScope?

    init(
        workspaceRoot: String,
        suggestsXcodeAnalysisTools: Bool = false,
        taskScope: AgentTaskPathScope? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.suggestsXcodeAnalysisTools = suggestsXcodeAnalysisTools
        self.taskScope = taskScope
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(
            workspaceRoot: workspaceRoot,
            suggestsXcodeAnalysisTools: suggestsXcodeAnalysisTools,
            taskScope: scope
        )
    }

    var name: String { "list_workspace" }
    var description: String {
        """
        List one directory inside the active workspace. Use this instead of
        file_system when the user asks to browse, inspect, or show files and
        folders. Pass only a workspace-relative directory path; use "." for the
        root. This tool is read-only and returns structured file metadata.
        After a successful call, do not repeat the directory entries as Markdown,
        a table, or a numbered list. TurboCode presents the result natively in the
        timeline. Add at most one short contextual sentence unless the user asks
        you to analyze the listing.
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
                    errorMessage: error.localizedDescription,
                    modelGuidance: nil
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
                errorMessage: nil,
                modelGuidance: xcodeAnalysisGuidance(for: entries)
            )
        } catch {
            return WorkspaceListingToolOutput(
                path: arguments.path,
                entries: [],
                totalCount: 0,
                isTruncated: false,
                errorMessage: error.localizedDescription,
                modelGuidance: nil
            )
        }
    }

    /// Llama benefits from an explicit next action after discovering an Xcode
    /// container; other profiles retain the compact listing-only payload.
    private func xcodeAnalysisGuidance(
        for entries: [WorkspaceListingToolEntry]
    ) -> String? {
        guard suggestsXcodeAnalysisTools,
              entries.contains(where: { entry in
                  let extensionName = URL(fileURLWithPath: entry.name)
                      .pathExtension
                      .lowercased()
                  return extensionName == "xcodeproj" || extensionName == "xcworkspace"
              }) else { return nil }

        return """
        An Xcode project or workspace is present. Continue the requested analysis
        without asking for confirmation. Use swift_workspace_map to orient around
        Swift declarations, read_file for relevant source ranges, toggle_skill
        with code-reader before grep when text search is needed, xcode_project for
        project discovery/build/test information, and git for repository state or
        changes. Call only the tools needed to complete the user's request.
        """
    }
}
