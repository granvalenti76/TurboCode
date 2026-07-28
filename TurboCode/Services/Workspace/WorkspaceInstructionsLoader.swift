import Foundation

/// Workspace-authored instructions that apply to every model working in the project.
///
/// The first implementation intentionally supports only the root `AGENTS.md`.
/// Loading every nested file up front would mix scopes and destabilize the
/// prompt prefix even when the current task never touches those directories.
nonisolated struct WorkspaceInstructions: Hashable, Sendable {
    let relativePath: String
    let content: String
    let revision: String
}

/// Loads the optional root `AGENTS.md` without making it a workspace requirement.
nonisolated enum WorkspaceInstructionsLoader {
    static let fileName = "AGENTS.md"
    static let maximumBytes = 32_000

    static func load(from workspaceRoot: String) -> WorkspaceInstructions? {
        guard !workspaceRoot.isEmpty,
              let fileURL = try? WorkspacePathResolver.resolve(
                  fileName,
                  within: workspaceRoot
              ) else {
            return nil
        }

        // Resolving symlinks through WorkspacePathResolver keeps an apparent
        // AGENTS.md from importing instructions stored outside the workspace.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: fileURL.path,
            isDirectory: &isDirectory
        ),
        !isDirectory.boolValue,
        FileManager.default.isReadableFile(atPath: fileURL.path),
        let values = try? fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ),
        values.isRegularFile == true,
        (values.fileSize ?? maximumBytes + 1) <= maximumBytes,
        let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
        data.count <= maximumBytes,
        let source = String(data: data, encoding: .utf8) else {
            return nil
        }

        let content = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return WorkspaceInstructions(
            relativePath: fileName,
            content: content,
            revision: FileRevision.hash(content)
        )
    }
}
