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
    /// Write content to a new or existing file (overwrite requires approval)
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
        - write: Write content to a file (creates parent directories; overwrite requires approval)
        - append: Append content to an existing file
        - copy: Copy a file or directory (requires destination)
        - move: Move or rename a file or directory (requires destination)
        - delete: Permanently delete a file or directory (requires approval)

        write and append require the 'content' argument.
        All paths must be within the workspace root.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: FileSystemArguments) async throws -> String {
        // 1. Resolve operation
        guard let operation = FileOperation(rawValue: arguments.operation) else {
            return "Error: Unknown operation '\(arguments.operation)'. Valid: \(FileOperation.allCases.map(\.rawValue).joined(separator: ", "))"
        }

        // 2. Validate path is within workspace
        try validatePath(arguments.path)

        // 3. For copy/move, validate destination too
        if let dest = arguments.destination, (operation == .copy || operation == .move) {
            try validatePath(dest)
        }

        // 4. Execute
        switch operation {
        case .list:              return listDirectory(at: arguments.path)
        case .info:              return fileInfo(at: arguments.path)
        case .find:              return findFiles(in: arguments.path, pattern: arguments.pattern)
        case .createDirectory:   return makeDirectory(at: arguments.path)
        case .write:
            guard let content = arguments.content else { return "Error: 'content' is required for write." }
            return writeFile(at: arguments.path, content: content)
        case .append:
            guard let content = arguments.content else { return "Error: 'content' is required for append." }
            return appendFile(at: arguments.path, content: content)
        case .copy:
            guard let dest = arguments.destination else { return "Error: 'destination' is required for copy." }
            return copyItem(from: arguments.path, to: dest)
        case .move:
            guard let dest = arguments.destination else { return "Error: 'destination' is required for move." }
            return moveItem(from: arguments.path, to: dest)
        case .delete:            return deleteItem(at: arguments.path)
        }
    }

    // MARK: - Path Validation

    private func validatePath(_ path: String) throws {
        guard !workspaceRoot.isEmpty else {
            throw FileSystemError.noWorkspace
        }

        let resolved = URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath().path
        let workspace = URL(fileURLWithPath: workspaceRoot).standardized.resolvingSymlinksInPath().path

        guard resolved.hasPrefix(workspace) else {
            throw FileSystemError.outsideWorkspace(path: path, workspace: workspaceRoot)
        }
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
            return "⚠️ ACTION REQUIRED: Destination already exists at '\(destination)'. Needs approval to overwrite."
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
            return "⚠️ ACTION REQUIRED: Destination already exists at '\(destination)'. Needs approval to overwrite."
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

        // Safety: never delete directly — require explicit approval
        return "\u{26A0}\u{FE0F} ACTION REQUIRED: Confirm deletion of '\(path)'. This action cannot be undone."
    }

    // MARK: - Write / Append

    private func writeFile(at path: String, content: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parentDir = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            return "Error creating parent directories: \(error.localizedDescription)"
        }

        if FileManager.default.fileExists(atPath: path) {
            return "\u{26A0}\u{FE0F} ACTION REQUIRED: File already exists at '\(path)'. Needs approval to overwrite."
        }

        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return "Created '\(path)' with \(content.utf8.count) bytes."
        } catch {
            return "Error writing '\(path)': \(error.localizedDescription)"
        }
    }

    private func appendFile(at path: String, content: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            return "Error: File not found at '\(path)'. Use 'write' to create a new file."
        }

        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(content.utf8))
            try handle.close()
            return "Appended \(content.utf8.count) bytes to '\(path)'."
        } catch {
            return "Error appending to '\(path)': \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func fmtDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
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

// MARK: - Simple glob matching for filenames

// MARK: - Simple glob matching (inline in findFiles to avoid actor isolation issues)
