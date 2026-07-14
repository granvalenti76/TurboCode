import Foundation
import FoundationModels

// MARK: - File System Tool

/// Operations the file system tool can perform.
enum FileOperation: String, CaseIterable, Sendable {
    /// List contents of a directory (safe)
    case list
    /// Get file/directory metadata (safe)
    case info
    /// Search for files matching a pattern (safe)
    case find
    /// Create a directory (creates intermediates)
    case createDirectory
    /// Write content to a new or existing file
    case write
    /// Append content to an existing file
    case append
    /// Copy a file or directory
    case copy
    /// Move or rename a file or directory
    case move
    /// Permanently delete a file or directory
    case delete
}

// MARK: - Arguments

@Generable
struct FileSystemArguments {
    /// Operation to perform: "list", "info", "find", "createDirectory", "write", "append", "copy", "move", "delete"
    var operation: String
    /// Path for the operation. For copy/move this is the source; for write/append the target file.
    var path: String
    /// Destination path (required for copy and move only).
    var destination: String?
    /// File name pattern (for find operation only, e.g. "*.swift").
    var pattern: String?
    /// Content to write (required for write and append operations only).
    var content: String?
}

// MARK: - Tool

/// Performs file system operations on the local machine using Foundation APIs.
/// All paths are validated against the workspace root for safety.
struct FileSystemTool: Tool {
    typealias Arguments = FileSystemArguments
    typealias Output = String

    let workspaceRoot: String

    var name: String { "file_system" }
    var description: String {
        """
        Perform file system operations on the workspace.
        Supported operations:
        - list: List contents of a directory
        - info: Get file metadata (size, dates, type)
        - find: Search for files matching a pattern
        - createDirectory: Create a new directory (parent directories are created automatically)
        - write: Write content through TurboCode's atomic change transaction
        - append: Append content through TurboCode's atomic change transaction
        - copy: Copy a file or directory (requires destination)
        - move: Move or rename a file or directory (requires destination)
        - delete: Permanently delete a file or directory (the only operation requiring approval)

        write and append require the 'content' argument and automatically produce the
        same Review/Undo change widget as the structured editing tools.
        Prefer read_file for numbered source ranges and the active structured editor
        for existing source and text files in Git workspaces. Use bash for builds, tests,
        Git queries, and commands that are not covered by these structured operations.
        All paths must be within the workspace root.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: FileSystemArguments) async throws -> String {
        // 1. Resolve operation
        guard let operation = FileOperation(rawValue: arguments.operation) else {
            return "Error: Unknown operation '\(arguments.operation)'. Valid: \(FileOperation.allCases.map(\.rawValue).joined(separator: ", "))"
        }

        // 2. Resolve paths (relative paths are resolved against workspaceRoot)
        let resolvedPath: String
        do {
            resolvedPath = try resolveAndValidatePath(arguments.path)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        var resolvedDest: String?
        if let dest = arguments.destination, (operation == .copy || operation == .move) {
            do {
                resolvedDest = try resolveAndValidatePath(dest)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }

        // 3. Execute
        switch operation {
        case .list:              return listDirectory(at: resolvedPath)
        case .info:              return fileInfo(at: resolvedPath)
        case .find:              return findFiles(in: resolvedPath, pattern: arguments.pattern)
        case .createDirectory:   return execute(operation: .createDirectory, path: resolvedPath, destination: nil, content: nil)
        case .write:
            guard let content = arguments.content else { return "Error: 'content' is required for write." }
            return try await applyTextChange(path: resolvedPath, content: content, append: false)
        case .append:
            guard let content = arguments.content else { return "Error: 'content' is required for append." }
            return try await applyTextChange(path: resolvedPath, content: content, append: true)
        case .copy:
            guard let dest = resolvedDest else { return "Error: 'destination' is required for copy." }
            return execute(operation: .copy, path: resolvedPath, destination: dest, content: nil)
        case .move:
            guard let dest = resolvedDest else { return "Error: 'destination' is required for move." }
            return execute(operation: .move, path: resolvedPath, destination: dest, content: nil)
        case .delete:            return await requestDeletionApproval(path: resolvedPath)
        }
    }

    // MARK: - Path Resolution & Validation

    /// Resolves a potentially relative path against the workspace root,
    /// then validates it's within the workspace boundary.
    /// Returns the resolved absolute path on success, throws on error.
    private func resolveAndValidatePath(_ path: String) throws -> String {
        try WorkspacePathResolver.resolve(path, within: workspaceRoot).path
    }

    // MARK: - Safe Operations

    private func listDirectory(at path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        ) else {
            return "Error: Cannot read directory '\(path)'"
        }

        guard !contents.isEmpty else { return "Directory is empty." }

        var lines: [String] = ["Contents of '\(path)':"]
        for item in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = resourceValues?.isDirectory ?? false
            let size = resourceValues?.fileSize ?? 0
            let date = resourceValues?.contentModificationDate
            let prefix = isDir ? "[DIR]" : "     "
            let sizeStr = isDir ? "       -" : String(format: "%8d", size)
            let dateStr = date.map { fmtDate($0) } ?? ""
            lines.append("\(prefix) \(sizeStr)  \(dateStr)  \(item.lastPathComponent)")
        }
        return lines.joined(separator: "\n")
    }

    private func fileInfo(at path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "Error: File or directory not found at '\(path)'"
        }

        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let size = attrs[.size] as? UInt64 ?? 0
        let created = attrs[.creationDate] as? Date
        let modified = attrs[.modificationDate] as? Date
        let perms = attrs[.posixPermissions] as? Int ?? 0

        return """
        Path: \(path)
        Type: \(isDir ? "directory" : "file")
        Size: \(size) bytes\(isDir ? " (metadata only)" : "")
        Created: \(created.map { fmtDate($0) } ?? "unknown")
        Modified: \(modified.map { fmtDate($0) } ?? "unknown")
        Permissions: \(String(format: "%03o", perms & 0o777))
        """
    }

    private func findFiles(in path: String, pattern: String?) -> String {
        // Use subpathsOfDirectory to avoid the enumator async unavailability issue
        guard let allSubpaths = try? FileManager.default.subpathsOfDirectory(atPath: path) else {
            return "Error: Cannot read directory '\(path)'"
        }

        // Filter: only regular files (not dirs), and match pattern
        let url = URL(fileURLWithPath: path)
        var matches: [String] = []
        let maxResults = 200

        for subpath in allSubpaths {
            guard matches.count < maxResults else { break }

            let fullPath = url.appendingPathComponent(subpath).path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            guard let pattern else {
                matches.append(subpath)
                continue
            }
            let filename = (subpath as NSString).lastPathComponent
            // Simple glob matching
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            let regexPattern = "^" + escaped
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            + "$"
            if let regex = try? NSRegularExpression(pattern: regexPattern) {
                let range = NSRange(filename.startIndex..., in: filename)
                if regex.firstMatch(in: filename, range: range) != nil {
                    matches.append(subpath)
                }
            }
        }

        guard !matches.isEmpty else {
            let patternMsg = pattern.map { " matching '\($0)'" } ?? ""
            return "No files found in '\(path)'\(patternMsg)."
        }

        var result = "Found \(matches.count) file\(matches.count == 1 ? "" : "s") in '\(path)'\(pattern.map { " matching '\($0)'" } ?? ""):"
        for match in matches.sorted() {
            result += "\n- \(url.appendingPathComponent(match).path)"
        }
        if matches.count >= maxResults {
            result += "\n... (truncated, too many results)"
        }
        return result
    }

    // MARK: - Destructive Operations

    private func makeDirectory(at path: String) -> String {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return "Created directory '\(path)'"
        } catch {
            return "Error creating directory '\(path)': \(error.localizedDescription)"
        }
    }

    private func copyItem(from source: String, to destination: String) -> String {
        guard FileManager.default.fileExists(atPath: source) else {
            return "Error: Source not found at '\(source)'"
        }

        if FileManager.default.fileExists(atPath: destination) {
            return "Error: Destination already exists at '\(destination)'. Delete it explicitly first."
        }

        do {
            try FileManager.default.copyItem(atPath: source, toPath: destination)
            return "Copied '\(source)' → '\(destination)'"
        } catch {
            return "Error copying '\(source)': \(error.localizedDescription)"
        }
    }

    private func moveItem(from source: String, to destination: String) -> String {
        guard FileManager.default.fileExists(atPath: source) else {
            return "Error: Source not found at '\(source)'"
        }

        if FileManager.default.fileExists(atPath: destination) {
            return "Error: Destination already exists at '\(destination)'. Delete it explicitly first."
        }

        do {
            try FileManager.default.moveItem(atPath: source, toPath: destination)
            return "Moved '\(source)' → '\(destination)'"
        } catch {
            return "Error moving '\(source)': \(error.localizedDescription)"
        }
    }

    private func deleteItem(at path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            return "Error: File or directory not found at '\(path)'"
        }

        do {
            try FileManager.default.removeItem(atPath: path)
            return "Deleted '\(path)'"
        } catch {
            return "Error deleting '\(path)': \(error.localizedDescription)"
        }
    }

    // MARK: - Transactional Text Changes

    private func applyTextChange(path: String, content: String, append: Bool) async throws -> String {
        let exists = FileManager.default.fileExists(atPath: path)
        if append && !exists {
            return "Error: File not found at '\(path)'. Use 'write' to create a new file."
        }

        let operation: LineEditOperation
        let revision: String?
        if exists {
            let original: String
            do {
                original = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                return "Error: '\(path)' is not a readable UTF-8 text file."
            }
            revision = FileRevision.hash(original)
            operation = LineEditOperation(
                operation: "replace_file",
                startLine: nil,
                endLine: nil,
                content: append ? original + content : content
            )
        } else {
            revision = nil
            operation = LineEditOperation(
                operation: "create",
                startLine: nil,
                endLine: nil,
                content: content
            )
        }

        let request = FileEditRequest(
            filePath: path,
            revision: revision,
            operations: [operation]
        )
        return try await ApplyEditsTool(workspaceRoot: workspaceRoot).call(
            arguments: ApplyEditsArguments(files: [request])
        )
    }

    // MARK: - Approval Gate

    private func requestDeletionApproval(path: String) async -> String {
        let id = UUID().uuidString
        let summary = "Delete '\(path)'. This action cannot be undone."
        let request = PendingToolApproval(
            id: id,
            operation: FileOperation.delete.rawValue,
            path: path,
            destination: nil,
            summary: summary,
            action: { [path] in
                deleteItem(at: path)
            }
        )
        await ToolApprovalRegistry.shared.register(request)

        return """
        TURBOCODE_APPROVAL_REQUIRED
        approval_id: \(id)
        operation: delete
        path: \(path)
        summary: \(summary)
        """
    }

    private func execute(
        operation: FileOperation,
        path: String,
        destination: String?,
        content: String?
    ) -> String {
        switch operation {
        case .createDirectory:
            return makeDirectory(at: path)
        case .write, .append:
            return "Error: Text writes must run through the asynchronous change transaction."
        case .copy:
            guard let destination else { return "Error: 'destination' is required for copy." }
            return copyItem(from: path, to: destination)
        case .move:
            guard let destination else { return "Error: 'destination' is required for move." }
            return moveItem(from: path, to: destination)
        case .delete:
            return deleteItem(at: path)
        case .list:
            return listDirectory(at: path)
        case .info:
            return fileInfo(at: path)
        case .find:
            return findFiles(in: path, pattern: nil)
        }
    }

    // MARK: - Helpers

    private func fmtDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - Tool Approval Registry

public struct PendingToolApproval: Sendable {
    public let id: String
    public let operation: String
    public let path: String
    public let destination: String?
    public let summary: String
    let action: @Sendable () async -> String
}

public actor ToolApprovalRegistry {
    public static let shared = ToolApprovalRegistry()

    private var requests: [String: PendingToolApproval] = [:]

    public func register(_ request: PendingToolApproval) async {
        requests[request.id] = request
        await MainActor.run {
            let presentation = ApprovalRequest(
                id: request.id,
                operation: request.operation,
                path: request.path,
                destination: request.destination,
                summary: request.summary
            )
            ChatStore.shared?.presentApproval(presentation)
        }
    }

    public func approve(id: String) async -> String {
        guard let request = requests.removeValue(forKey: id) else {
            return "Error: Approval request expired or was already handled."
        }
        return await request.action()
    }

    public func reject(id: String) {
        requests.removeValue(forKey: id)
    }
}

// MARK: - Errors

enum FileSystemError: LocalizedError {
    case noWorkspace
    case outsideWorkspace(path: String, workspace: String)

    var errorDescription: String? {
        switch self {
        case .noWorkspace:
            return "No workspace is set. Choose a workspace folder first."
        case .outsideWorkspace(let path, let workspace):
            return "Access denied: '\(path)' is outside the workspace '\(workspace)'."
        }
    }
}

// MARK: - Shared Workspace Path Validation

/// Resolves relative and absolute paths while enforcing a strict workspace
/// boundary. Both the workspace and candidate are symlink-resolved so a link
/// inside the workspace cannot be used to access files outside it.
enum WorkspacePathResolver {
    nonisolated static func resolve(_ path: String, within workspaceRoot: String) throws -> URL {
        guard !workspaceRoot.isEmpty else {
            throw FileSystemError.noWorkspace
        }

        let workspaceURL = URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let candidateURL: URL
        if (path as NSString).isAbsolutePath {
            candidateURL = URL(fileURLWithPath: path)
        } else {
            candidateURL = workspaceURL.appendingPathComponent(path)
        }

        let resolvedURL = candidateURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let workspacePath = workspaceURL.path
        let candidatePath = resolvedURL.path

        guard candidatePath == workspacePath
                || candidatePath.hasPrefix(workspacePath + "/") else {
            throw FileSystemError.outsideWorkspace(path: path, workspace: workspaceRoot)
        }

        return resolvedURL
    }
}

// MARK: - Simple glob matching for filenames

// MARK: - Simple glob matching (inline in findFiles to avoid actor isolation issues)
