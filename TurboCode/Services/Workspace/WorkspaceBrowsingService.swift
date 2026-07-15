import Foundation

nonisolated struct WorkspaceDirectorySnapshot: Sendable {
    let relativePath: String
    let entries: [WorkspaceDirectoryEntrySnapshot]
    let totalCount: Int
    let isTruncated: Bool
}

nonisolated struct WorkspaceDirectoryEntrySnapshot: Sendable {
    let name: String
    let relativePath: String
    let kind: WorkspaceListingEntryKind
    let sizeBytes: Int?
    let modifiedAt: Date?
    let fileExtension: String?
}

nonisolated enum WorkspaceBrowsingError: LocalizedError {
    case notDirectory(String)
    case unreadableDirectory(String)

    var errorDescription: String? {
        switch self {
        case .notDirectory(let path):
            "The workspace path is not a directory: \(path)"
        case .unreadableDirectory(let path):
            "The workspace directory cannot be read: \(path)"
        }
    }
}

/// Read-only, workspace-bounded directory inspection. It owns filesystem
/// semantics and returns domain snapshots without knowing about model tools or UI.
nonisolated struct WorkspaceBrowsingService: Sendable {
    let workspaceRoot: String

    func listDirectory(at path: String, maximumEntries: Int = 100) throws -> WorkspaceDirectorySnapshot {
        let rootURL = try WorkspacePathResolver.resolve(".", within: workspaceRoot)
        let directoryURL = try WorkspacePathResolver.resolve(path, within: workspaceRoot)
        let directoryValues = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey])
        guard directoryValues?.isDirectory == true else {
            throw WorkspaceBrowsingError.notDirectory(path)
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        } catch {
            throw WorkspaceBrowsingError.unreadableDirectory(path)
        }

        let snapshots = contents.compactMap { item -> WorkspaceDirectoryEntrySnapshot? in
            guard let values = try? item.resourceValues(forKeys: keys) else { return nil }
            let kind: WorkspaceListingEntryKind
            if values.isSymbolicLink == true {
                kind = .symbolicLink
            } else if values.isDirectory == true {
                kind = .directory
            } else {
                kind = .file
            }
            return WorkspaceDirectoryEntrySnapshot(
                name: item.lastPathComponent,
                relativePath: relativePath(for: item, rootURL: rootURL),
                kind: kind,
                sizeBytes: kind == .directory ? nil : values.fileSize,
                modifiedAt: values.contentModificationDate,
                fileExtension: kind == .file && !item.pathExtension.isEmpty
                    ? item.pathExtension.lowercased()
                    : nil
            )
        }.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                if lhs.kind == .directory { return true }
                if rhs.kind == .directory { return false }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let limit = max(1, maximumEntries)
        return WorkspaceDirectorySnapshot(
            relativePath: relativePath(for: directoryURL, rootURL: rootURL),
            entries: Array(snapshots.prefix(limit)),
            totalCount: snapshots.count,
            isTruncated: snapshots.count > limit
        )
    }

    private func relativePath(for url: URL, rootURL: URL) -> String {
        if url.path == rootURL.path { return "." }
        return String(url.path.dropFirst(rootURL.path.count + 1))
    }
}
