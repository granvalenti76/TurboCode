import Foundation
import FoundationModels

// MARK: - File System Tool

/// Operations the file system tool can perform.
nonisolated enum FileOperation: String, CaseIterable, Sendable {
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

    /// Read-only operations can safely target the workspace root itself.
    var allowsWorkspaceRoot: Bool {
        switch self {
        case .list, .info, .find:
            true
        case .createDirectory, .write, .append, .copy, .move, .delete:
            false
        }
    }
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
    /// UTF-8 content for write/append. Preserve newlines; separate prose paragraphs with a blank line.
    var content: String?
}

// MARK: - Tool

/// Performs file system operations on the local machine using Foundation APIs.
/// External targets cross the shared host-owned approval ring before execution.
struct FileSystemTool: Tool {
    typealias Arguments = FileSystemArguments
    typealias Output = ToolCommandOutput

    let workspaceRoot: String
    let taskScope: AgentTaskPathScope?
    private let receiptRegistry: ToolReceiptRegistry?
    private let requestApproval: @Sendable (PendingToolApproval) async -> String

    init(
        workspaceRoot: String,
        taskScope: AgentTaskPathScope? = nil,
        receiptRegistry: ToolReceiptRegistry? = nil,
        requestApproval: @escaping @Sendable (PendingToolApproval) async -> String = {
            await ToolApprovalRegistry.shared.request($0)
        }
    ) {
        self.workspaceRoot = workspaceRoot
        self.taskScope = taskScope
        self.receiptRegistry = receiptRegistry
        self.requestApproval = requestApproval
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(
            workspaceRoot: workspaceRoot,
            taskScope: scope,
            receiptRegistry: receiptRegistry,
            requestApproval: requestApproval
        )
    }

    var name: String { "file_system" }
    var description: String {
        """
        Perform file system operations on workspace or absolute paths. Operations
        outside the active workspace continue after host approval.
        Supported operations:
        - list: List directory contents
        - info: Get file metadata (size, dates, type)
        - find: Search for files matching a pattern
        - createDirectory: Create a new directory (parent directories are created automatically)
        - write: Write content through TurboCode's atomic change transaction
        - append: Append content through TurboCode's atomic change transaction
        - copy: Copy a file or directory (requires destination)
        - move: Move or rename a file or directory (requires destination and approval)
        - delete: Permanently delete a file or directory (requires approval)

        write and append require the 'content' argument and automatically produce the
        same Review/Undo change widget as the structured editing tools.
        For articles, biographies, documentation, and other long-form prose, preserve
        readable paragraphs separated by blank lines. Never write the whole document
        as one long line.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: FileSystemArguments) async throws -> ToolCommandOutput {
        // 1. Resolve operation
        guard let operation = FileOperation(rawValue: arguments.operation) else {
            return "Error: Unknown operation '\(arguments.operation)'. Valid: \(FileOperation.allCases.map(\.rawValue).joined(separator: ", "))"
        }

        // Relative paths start at the active workspace; absolute paths keep
        // their normal filesystem meaning and cross the approval ring if needed.
        let source: ResolvedWorkspacePath
        do {
            source = try resolveTarget(
                arguments.path,
                allowingWorkspaceRoot: operation.allowsWorkspaceRoot
            )
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        var destination: ResolvedWorkspacePath?
        if let dest = arguments.destination, (operation == .copy || operation == .move) {
            do {
                destination = try resolveTarget(dest, allowingWorkspaceRoot: false)
            } catch {
                return "Error: \(error.localizedDescription)"
            }
        }

        if operation == .write || operation == .append {
            guard let content = arguments.content else {
                return "Error: 'content' is required for \(operation.rawValue)."
            }
            if !source.isInsideWorkspace {
                let relay = ToolCommandOutputRelay()
                let approvalText = await WorkspaceAccessGate.shared.performExternalOperation(
                    tool: name,
                    operation: .write,
                    workspaceRoot: workspaceRoot,
                    targets: [source],
                    requestApproval: requestApproval,
                    action: { [self] in
                        do {
                            let output = try await applyTextChange(
                                path: source.url.path,
                                content: content,
                                append: operation == .append,
                                preauthorizedExternalPaths: [source.url.path]
                            )
                            await relay.store(output)
                            return output.text
                        } catch {
                            return "Error: \(error.localizedDescription)"
                        }
                    }
                )
                return await relay.take() ?? .plain(approvalText)
            }
            return try await applyTextChange(
                path: source.url.path,
                content: content,
                append: operation == .append,
                preauthorizedExternalPaths: []
            )
        }

        let resolvedDestination = destination
        let targets = [source, resolvedDestination].compactMap { $0 }
        if targets.contains(where: { !$0.isInsideWorkspace }) {
            // Destructive actions retain change detection while using the
            // external ring as their single approval instead of stacking gates.
            let expectedSnapshots = operation == .move || operation == .delete
                ? targets.map { fileSnapshot(at: $0.url.path) }
                : nil
            let relay = ToolCommandOutputRelay()
            let approvalText = await WorkspaceAccessGate.shared.performExternalOperation(
                tool: name,
                operation: accessOperation(for: operation),
                workspaceRoot: workspaceRoot,
                targets: targets,
                requestApproval: requestApproval,
                action: { [self] in
                    if let expectedSnapshots,
                       zip(targets, expectedSnapshots).contains(where: {
                           fileSnapshot(at: $0.0.url.path) != $0.1
                       }) {
                        return "Error: The destructive target changed before approval."
                    }
                    let output = await executeResolved(
                        operation: operation,
                        path: source.url.path,
                        destination: resolvedDestination?.url.path,
                        pattern: arguments.pattern,
                        bypassDestructiveApproval: true
                    )
                    await relay.store(output)
                    return output.text
                }
            )
            return await relay.take() ?? .plain(approvalText)
        }

        return await executeResolved(
            operation: operation,
            path: source.url.path,
            destination: resolvedDestination?.url.path,
            pattern: arguments.pattern,
            bypassDestructiveApproval: false
        )
    }

    private func executeResolved(
        operation: FileOperation,
        path: String,
        destination: String?,
        pattern: String?,
        bypassDestructiveApproval: Bool
    ) async -> ToolCommandOutput {
        switch operation {
        case .list: return .plain(listDirectory(at: path))
        case .info: return .plain(fileInfo(at: path))
        case .find: return .plain(await findFiles(in: path, pattern: pattern))
        case .createDirectory:
            return .plain(await execute(
                operation: .createDirectory,
                path: path,
                destination: nil,
                content: nil
            ))
        case .write, .append:
            return "Error: Text mutations must use the atomic edit path."
        case .copy:
            guard let destination else { return "Error: 'destination' is required for copy." }
            return .plain(await execute(operation: .copy, path: path, destination: destination, content: nil))
        case .move:
            guard let destination else { return "Error: 'destination' is required for move." }
            if bypassDestructiveApproval {
                return .plain(await execute(operation: .move, path: path, destination: destination, content: nil))
            }
            return .plain(await requestMoveApproval(
                path: path,
                destination: destination,
                requestedPath: path,
                requestedDestination: destination
            ))
        case .delete:
            if bypassDestructiveApproval {
                return .plain(await execute(operation: .delete, path: path, destination: nil, content: nil))
            }
            return .plain(await requestDeletionApproval(
                path: path,
                requestedPath: path
            ))
        }
    }

    // MARK: - Path Resolution & Validation

    /// Re-resolves a workspace path immediately before a destructive action.
    /// Returns the resolved absolute path on success, throws on error.
    private func resolveAndValidatePath(
        _ path: String,
        allowingWorkspaceRoot: Bool
    ) throws -> String {
        let resolvedPath = try WorkspacePathResolver.resolve(path, within: workspaceRoot).path

        if !allowingWorkspaceRoot {
            let workspacePath = try WorkspacePathResolver.resolve(".", within: workspaceRoot).path
            guard resolvedPath != workspacePath else {
                throw FileSystemError.workspaceRootMutation
            }
        }
        return resolvedPath
    }

    private func resolveTarget(
        _ path: String,
        allowingWorkspaceRoot: Bool
    ) throws -> ResolvedWorkspacePath {
        let target = try WorkspacePathResolver.resolveForAccess(
            path,
            within: workspaceRoot
        )
        if !allowingWorkspaceRoot,
           target.isInsideWorkspace,
           target.url.path == URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL.resolvingSymlinksInPath().path {
            throw FileSystemError.workspaceRootMutation
        }
        return target
    }

    private func accessOperation(for operation: FileOperation) -> WorkspaceAccessOperation {
        switch operation {
        case .list, .info, .find:
            .read
        case .createDirectory, .write, .append, .copy:
            .write
        case .move, .delete:
            .destructive
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

    private func findFiles(in path: String, pattern: String?) async -> String {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else {
            return "Error: Cannot read directory '\(path)'"
        }

        // Enumerate lazily so a large workspace is not materialized in memory
        // before the result limit can stop the search.
        let url = URL(fileURLWithPath: path)
        var matches: [String] = []
        let maxResults = 200
        var truncated = false

        let regex: NSRegularExpression?
        if let pattern {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            let regexPattern = "^" + escaped
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            + "$"
            guard let compiled = try? NSRegularExpression(pattern: regexPattern) else {
                return "Error: Invalid file pattern '\(pattern)'."
            }
            regex = compiled
        } else {
            regex = nil
        }

        while let entry = enumerator.nextObject() {
            guard !Task.isCancelled else { return "Search cancelled." }
            guard let subpath = entry as? String else { continue }
            let entryURL = url.appendingPathComponent(subpath)
            let values = try? entryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true else { continue }

            let filename = (subpath as NSString).lastPathComponent
            let range = NSRange(filename.startIndex..., in: filename)
            let matchesPattern = regex?.firstMatch(in: filename, range: range) != nil
                || regex == nil
            guard matchesPattern else { continue }

            if matches.count == maxResults {
                // Inspect one additional match so exactly 200 results are not
                // incorrectly reported as truncated.
                truncated = true
                break
            }
            matches.append(subpath)
        }

        guard !matches.isEmpty else {
            let patternMsg = pattern.map { " matching '\($0)'" } ?? ""
            return "No files found in '\(path)'\(patternMsg)."
        }

        var result = "Found \(matches.count) file\(matches.count == 1 ? "" : "s") in '\(path)'\(pattern.map { " matching '\($0)'" } ?? ""):"
        for match in matches.sorted() {
            result += "\n- \(url.appendingPathComponent(match).path)"
        }
        if truncated {
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

    private func applyTextChange(
        path: String,
        content: String,
        append: Bool,
        preauthorizedExternalPaths: Set<String>
    ) async throws -> ToolCommandOutput {
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
        return try await ApplyEditsTool(
            workspaceRoot: workspaceRoot,
            preauthorizedExternalPaths: preauthorizedExternalPaths,
            receiptRegistry: receiptRegistry,
            requestApproval: requestApproval
        ).call(
            arguments: ApplyEditsArguments(files: [request])
        )
    }

    // MARK: - Approval Gate

    private func requestDeletionApproval(path: String, requestedPath: String) async -> String {
        let summary = "Delete '\(path)'. This action cannot be undone."
        let expectedSnapshot = fileSnapshot(at: path)
        let request = PendingToolApproval(
            id: UUID().uuidString,
            operation: FileOperation.delete.rawValue,
            path: path,
            destination: nil,
            summary: summary,
            action: { [self, path, requestedPath, expectedSnapshot] in
                do {
                    let currentPath = try resolveAndValidatePath(
                        requestedPath,
                        allowingWorkspaceRoot: false
                    )
                    guard currentPath == path else {
                        return "Error: The deletion target changed before approval."
                    }
                    guard fileSnapshot(at: currentPath) == expectedSnapshot else {
                        return "Error: The deletion target changed before approval."
                    }
                    return deleteItem(at: currentPath)
                } catch {
                    return "Error: \(error.localizedDescription)"
                }
            }
        )
        // Keep the model turn suspended until the user decision is resolved;
        // the final result is then returned as the tool output directly.
        return await requestApproval(request)
    }

    private func requestMoveApproval(
        path: String,
        destination: String,
        requestedPath: String,
        requestedDestination: String
    ) async -> String {
        // Moving changes the source namespace and cannot be represented by the
        // existing review/undo transaction, so keep it behind explicit approval.
        let summary = "Move '\(path)' to '\(destination)'."
        let expectedSourceSnapshot = fileSnapshot(at: path)
        let expectedDestinationSnapshot = fileSnapshot(at: destination)
        let request = PendingToolApproval(
            id: UUID().uuidString,
            operation: FileOperation.move.rawValue,
            path: path,
            destination: destination,
            summary: summary,
            action: { [self, path, destination, requestedPath, requestedDestination, expectedSourceSnapshot, expectedDestinationSnapshot] in
                do {
                    let currentPath = try resolveAndValidatePath(
                        requestedPath,
                        allowingWorkspaceRoot: false
                    )
                    let currentDestination = try resolveAndValidatePath(
                        requestedDestination,
                        allowingWorkspaceRoot: false
                    )
                    guard currentPath == path, currentDestination == destination else {
                        return "Error: The move target changed before approval."
                    }
                    guard fileSnapshot(at: currentPath) == expectedSourceSnapshot,
                          fileSnapshot(at: currentDestination) == expectedDestinationSnapshot else {
                        return "Error: The move target changed before approval."
                    }
                    return moveItem(from: currentPath, to: currentDestination)
                } catch {
                    return "Error: \(error.localizedDescription)"
                }
            }
        )
        return await requestApproval(request)
    }

    private func fileSnapshot(at path: String) -> FileSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return FileSnapshot(
            type: String(describing: attributes[.type]),
            size: attributes[.size] as? UInt64,
            creationDate: attributes[.creationDate] as? Date,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    private func execute(
        operation: FileOperation,
        path: String,
        destination: String?,
        content: String?
    ) async -> String {
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
            return await findFiles(in: path, pattern: nil)
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
    public let command: String?
    let action: @Sendable () async -> String

    nonisolated init(
        id: String,
        operation: String,
        path: String,
        destination: String?,
        summary: String,
        command: String? = nil,
        action: @escaping @Sendable () async -> String
    ) {
        self.id = id
        self.operation = operation
        self.path = path
        self.destination = destination
        self.summary = summary
        self.command = command
        self.action = action
    }
}

public actor ToolApprovalRegistry {
    public static let shared = ToolApprovalRegistry()

    private struct RegisteredApproval {
        let request: PendingToolApproval
        let continuation: CheckedContinuation<String, Never>?
    }

    private var requests: [String: RegisteredApproval] = [:]

    public func register(_ request: PendingToolApproval) async {
        requests[request.id] = RegisteredApproval(request: request, continuation: nil)
        await present(request)
    }

    /// Suspends a tool call until the user explicitly approves or rejects it.
    /// The model receives only the final result returned by this method.
    public func request(_ request: PendingToolApproval) async -> String {
        guard !Task.isCancelled else { return "Action cancelled." }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                requests[request.id] = RegisteredApproval(
                    request: request,
                    continuation: continuation
                )
                Task { await self.present(request) }
            }
        } onCancel: {
            Task { await self.cancel(id: request.id) }
        }
    }

    private func present(_ request: PendingToolApproval) async {
        let presentation = ApprovalRequest(
            id: request.id,
            operation: request.operation,
            path: request.path,
            destination: request.destination,
            summary: request.summary,
            command: request.command
        )
        await ToolApprovalPresentationBroker.shared.publish(.present(presentation))
    }

    public func approve(id: String) async -> ToolApprovalResolution {
        guard let registered = requests.removeValue(forKey: id) else {
            return ToolApprovalResolution(
                result: "Error: Approval request expired or was already handled.",
                requiresModelFollowUp: false
            )
        }
        let result = await registered.request.action()
        registered.continuation?.resume(returning: result)
        return ToolApprovalResolution(
            result: result,
            requiresModelFollowUp: registered.continuation == nil
        )
    }

    public func reject(id: String) -> ToolApprovalResolution {
        guard let registered = requests.removeValue(forKey: id) else {
            return ToolApprovalResolution(
                result: "Action cancelled by the user.",
                requiresModelFollowUp: false
            )
        }
        let result = "Action cancelled by the user."
        registered.continuation?.resume(returning: result)
        return ToolApprovalResolution(
            result: result,
            requiresModelFollowUp: registered.continuation == nil
        )
    }

    private func cancel(id: String) async {
        guard let registered = requests.removeValue(forKey: id) else { return }
        registered.continuation?.resume(returning: "Action cancelled.")
        await ToolApprovalPresentationBroker.shared.publish(.dismiss(id))
    }
}

public struct ToolApprovalResolution: Sendable {
    public let result: String
    public let requiresModelFollowUp: Bool
}

// MARK: - Errors

enum FileSystemError: LocalizedError {
    case noWorkspace
    case outsideWorkspace(path: String, workspace: String)
    case workspaceRootMutation

    var errorDescription: String? {
        switch self {
        case .noWorkspace:
            return "No workspace is set. Choose a workspace folder first."
        case .outsideWorkspace(let path, let workspace):
            return "Access denied: '\(path)' is outside the workspace '\(workspace)'."
        case .workspaceRootMutation:
            return "Access denied: mutating the workspace root itself is not allowed."
        }
    }
}

private struct FileSnapshot: Sendable, Equatable {
    let type: String
    let size: UInt64?
    let creationDate: Date?
    let modificationDate: Date?
}

// MARK: - Shared Workspace Path Validation

/// A canonical filesystem target together with the unresolved URL needed to
/// detect symlink retargeting while an external approval is pending.
nonisolated struct ResolvedWorkspacePath: Sendable, Equatable {
    let requestedURL: URL
    let url: URL
    let isInsideWorkspace: Bool
}

/// Resolves relative and absolute paths. Callers that are strictly
/// workspace-bound use `resolve`; tools with a host approval path use
/// `resolveForAccess` and send external targets through `WorkspaceAccessGate`.
enum WorkspacePathResolver {
    nonisolated static func resolve(_ path: String, within workspaceRoot: String) throws -> URL {
        let target = try resolveForAccess(path, within: workspaceRoot)
        guard target.isInsideWorkspace else {
            throw FileSystemError.outsideWorkspace(path: path, workspace: workspaceRoot)
        }
        return target.url
    }

    nonisolated static func resolveForAccess(
        _ path: String,
        within workspaceRoot: String
    ) throws -> ResolvedWorkspacePath {
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

        let requestedURL = candidateURL.standardizedFileURL
        let resolvedURL = requestedURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let workspacePath = workspaceURL.path
        let candidatePath = resolvedURL.path
        return ResolvedWorkspacePath(
            requestedURL: requestedURL,
            url: resolvedURL,
            isInsideWorkspace: candidatePath == workspacePath
                || candidatePath.hasPrefix(workspacePath + "/")
        )
    }

    nonisolated static func isUnchanged(_ target: ResolvedWorkspacePath) -> Bool {
        target.requestedURL.standardizedFileURL.resolvingSymlinksInPath() == target.url
    }

    /// Generated edit patches remain relative and reversible by using the
    /// narrowest common root that contains the workspace and approved targets.
    nonisolated static func transactionRoot(
        workspaceRoot: String,
        targets: [ResolvedWorkspacePath]
    ) -> String {
        let urls = [URL(fileURLWithPath: workspaceRoot).standardizedFileURL]
            + targets.map(\.url)
        guard var common = urls.first?.pathComponents else { return workspaceRoot }
        for url in urls.dropFirst() {
            let components = url.pathComponents
            let sharedCount = zip(common, components)
                .prefix { $0.0 == $0.1 }
                .count
            common = Array(common.prefix(sharedCount))
        }
        return NSString.path(withComponents: common)
    }
}

// MARK: - Simple glob matching for filenames

// MARK: - Simple glob matching (inline in findFiles to avoid actor isolation issues)
