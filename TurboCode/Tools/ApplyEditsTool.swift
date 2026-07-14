import CryptoKit
import Foundation
import FoundationModels

enum FileRevision {
    nonisolated static func hash(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@Generable
struct LineEditOperation {
    /// Operation: replace_lines, insert_before, insert_after, delete_lines, replace_file, or create.
    var operation: String
    /// First one-based line for replace/delete, or anchor line for insert operations.
    var startLine: Int?
    /// Last inclusive one-based line for replace/delete. Defaults to startLine.
    var endLine: Int?
    /// Replacement, inserted, or new-file UTF-8 content. Omit for delete_lines.
    var content: String?
}

@Generable
struct FileEditRequest {
    /// Absolute or workspace-relative path of the text file.
    var filePath: String
    /// Revision returned by the latest read_file call. Required for existing files.
    var revision: String?
    /// Operations expressed against that unchanged revision.
    var operations: [LineEditOperation]
}

@Generable
struct ApplyEditsArguments {
    /// One or more files to edit atomically.
    var files: [FileEditRequest]
}

@Generable
struct EditFileArguments {
    /// Absolute or workspace-relative path of one UTF-8 text file.
    var filePath: String
    /// Revision from read_file, or an empty string only when creating a new file.
    var revision: String
    /// Exactly one operation: replace_lines, insert_before, insert_after, delete_lines, replace_file, or create.
    @Guide(.anyOf(["replace_lines", "insert_before", "insert_after", "delete_lines", "replace_file", "create"]))
    var operation: String
    /// First one-based line. Use 0 for create or replace_file.
    var startLine: Int
    /// Last inclusive one-based line. Use startLine for insert operations and 0 for create or replace_file.
    var endLine: Int
    /// New UTF-8 text. Preserve intentional newlines. For prose with multiple paragraphs, separate paragraphs with a blank line (two newline characters). Use an empty string only for delete_lines.
    var content: String
}

struct ApplyEditsTool: Tool {
    typealias Arguments = ApplyEditsArguments
    typealias Output = String

    let workspaceRoot: String
    let reportsChanges: Bool
    private let editService = ApplyEditsService()
    private let patchService = DiffPatchService()

    init(workspaceRoot: String, reportsChanges: Bool = true) {
        self.workspaceRoot = workspaceRoot
        self.reportsChanges = reportsChanges
    }

    var name: String { "apply_edits" }
    var description: String {
        """
        Atomically create or edit UTF-8 text files in the active workspace. First use read_file
        to obtain current line numbers and the file revision. For existing files, provide
        that revision and use replace_lines, insert_before, insert_after, or delete_lines.
        All line numbers refer to the same original revision; TurboCode handles ordering,
        generates and validates the unified diff, updates the change widget, and applies
        the transaction automatically. To create a file, use one create operation with
        its complete content and omit revision. replace_file is available only when the
        complete current file was read and a whole-file rewrite is truly needed. Never
        generate unified diff hunks yourself.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: ApplyEditsArguments) async throws -> String {
        let transactionID = UUID().uuidString
        let prepared: PreparedChangeTransaction
        do {
            prepared = try await editService.prepare(arguments: arguments, workspaceRoot: workspaceRoot)
            try await patchService.check(patch: prepared.patch, workspaceRoot: workspaceRoot)
        } catch {
            return "Edit transaction rejected: \(error.localizedDescription) Re-read the affected ranges and retry using the new revision."
        }

        if reportsChanges {
            await MainActor.run {
                ChatStore.shared?.beginDiffPatchBlock(
                    id: transactionID,
                    patch: prepared.patch,
                    files: prepared.files,
                    status: .running
                )
            }
        }

        do {
            try await patchService.apply(patch: prepared.patch, workspaceRoot: workspaceRoot)
            if reportsChanges {
                await MainActor.run {
                    ChatStore.shared?.updateDiffPatchBlock(id: transactionID, status: .applied)
                }
            }
            return "Applied \(prepared.files.count) file change(s): +\(prepared.additions) -\(prepared.deletions)."
        } catch {
            if reportsChanges {
                await MainActor.run {
                    ChatStore.shared?.updateDiffPatchBlock(
                        id: transactionID,
                        status: .failed,
                        errorMessage: error.localizedDescription
                    )
                }
            }
            return "Edit transaction failed: \(error.localizedDescription)"
        }
    }
}

/// A deliberately flat editing schema for smaller models. Execution still
/// converges on the same revision checks, patch validation, widget, and Undo.
struct EditFileTool: Tool {
    typealias Arguments = EditFileArguments
    typealias Output = String

    let workspaceRoot: String
    let reportsChanges: Bool

    init(workspaceRoot: String, reportsChanges: Bool = true) {
        self.workspaceRoot = workspaceRoot
        self.reportsChanges = reportsChanges
    }

    var name: String { "edit_file" }
    var description: String {
        """
        Apply one atomic change to one UTF-8 text file. Read the relevant range with
        read_file immediately before editing and copy its Revision exactly. Choose one
        operation. For replace_lines and delete_lines, startLine and endLine are the
        inclusive one-based range. For insert_before or insert_after, set both line
        values to the anchor line. For create, use revision "", line values 0, and the
        complete new-file content. For replace_file, use a current revision, line values
        0, and complete replacement content. Use content "" only for delete_lines.
        TurboCode generates and validates the internal patch and updates the change widget.
        Preserve the requested document layout in content. Long-form prose, articles,
        biographies, and documentation must use readable paragraphs separated by a
        blank line; never collapse an entire document into one long line.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: EditFileArguments) async throws -> String {
        let usesLineRange = !["create", "replace_file"].contains(arguments.operation)
        let operation = LineEditOperation(
            operation: arguments.operation,
            startLine: usesLineRange ? arguments.startLine : nil,
            endLine: usesLineRange ? arguments.endLine : nil,
            content: arguments.operation == "delete_lines" ? nil : arguments.content
        )
        let request = FileEditRequest(
            filePath: arguments.filePath,
            revision: arguments.revision.isEmpty ? nil : arguments.revision,
            operations: [operation]
        )
        return try await ApplyEditsTool(
            workspaceRoot: workspaceRoot,
            reportsChanges: reportsChanges
        ).call(
            arguments: ApplyEditsArguments(files: [request])
        )
    }
}

struct PreparedChangeTransaction: Sendable {
    let patch: String
    let files: [DiffPatchFileChange]

    nonisolated var additions: Int { files.reduce(0) { $0 + $1.additions } }
    nonisolated var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

private struct PreparedLineEdit {
    let range: Range<Int>
    let replacement: [String]
}

actor ApplyEditsService {
    func prepare(arguments: ApplyEditsArguments, workspaceRoot: String) throws -> PreparedChangeTransaction {
        guard !arguments.files.isEmpty else {
            throw DiffPatchError.invalidEdit("No files were provided.")
        }

        var seenPaths = Set<String>()
        var changes: [(path: String, old: String?, new: String)] = []
        for request in arguments.files {
            let url = try WorkspacePathResolver.resolve(request.filePath, within: workspaceRoot)
            let relativePath = try relativePath(for: url, workspaceRoot: workspaceRoot)
            guard seenPaths.insert(relativePath).inserted else {
                throw DiffPatchError.invalidEdit("File '\(relativePath)' appears more than once in the transaction.")
            }
            guard !request.operations.isEmpty else {
                throw DiffPatchError.invalidEdit("No operations were provided for '\(relativePath)'.")
            }
            for operation in request.operations {
                if let content = operation.content {
                    try validateContentLayout(content, path: relativePath, operation: operation)
                }
            }

            let exists = FileManager.default.fileExists(atPath: url.path)
            if !exists {
                guard request.operations.count == 1,
                      request.operations[0].operation == "create",
                      let content = request.operations[0].content else {
                    throw DiffPatchError.invalidEdit("Missing file '\(relativePath)' requires one create operation.")
                }
                guard request.revision == nil else {
                    throw DiffPatchError.invalidEdit("New file '\(relativePath)' must not include a revision.")
                }
                changes.append((relativePath, nil, content))
                continue
            }

            guard !request.operations.contains(where: { $0.operation == "create" }) else {
                throw DiffPatchError.invalidEdit("File '\(relativePath)' already exists and cannot use create.")
            }
            let original = try String(contentsOf: url, encoding: .utf8)
            guard let revision = request.revision, revision == FileRevision.hash(original) else {
                throw DiffPatchError.invalidEdit("Revision mismatch for '\(relativePath)'.")
            }
            let updated = try apply(request.operations, to: original, path: relativePath)
            guard updated != original else {
                throw DiffPatchError.invalidEdit("Operations would not change '\(relativePath)'.")
            }
            changes.append((relativePath, original, updated))
        }

        let patch = try makePatch(changes: changes)
        let files = try DiffPatchParser.parse(patch, workspaceRoot: workspaceRoot)
        return PreparedChangeTransaction(patch: patch, files: files)
    }

    private func validateContentLayout(
        _ content: String,
        path: String,
        operation: LineEditOperation
    ) throws {
        try validateProseLayout(content, path: path)
        try validateSourceLayout(content, path: path, operation: operation)
    }

    private func validateProseLayout(_ content: String, path: String) throws {
        let proseExtensions = Set(["txt", "md", "markdown", "rst"])
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard proseExtensions.contains(fileExtension),
              content.count >= 180,
              !content.contains("\n") else { return }

        let sentenceMarks = content.reduce(into: 0) { count, character in
            if character == "." || character == "!" || character == "?" {
                count += 1
            }
        }
        guard sentenceMarks >= 2 else { return }
        throw DiffPatchError.invalidEdit(
            "Long-form prose for '\(path)' was collapsed into one line. Retry with readable paragraphs separated by a blank line (two newline characters)."
        )
    }

    private func validateSourceLayout(
        _ content: String,
        path: String,
        operation: LineEditOperation
    ) throws {
        let sourceExtensions = Set([
            "swift", "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm",
            "java", "kt", "kts", "js", "jsx", "ts", "tsx", "py", "rs", "go"
        ])
        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard sourceExtensions.contains(fileExtension),
              content.count >= 120,
              !content.contains("\n") else { return }

        let rewritesWholeFile = operation.operation == "create"
            || operation.operation == "replace_file"
        let replacesMultipleLines = operation.operation == "replace_lines"
            && (operation.endLine ?? operation.startLine ?? 0)
                > (operation.startLine ?? 0)
        guard rewritesWholeFile || replacesMultipleLines else { return }

        throw DiffPatchError.invalidEdit(
            "Source code for '\(path)' was collapsed into one line. Retry with the original code structure and real newline characters."
        )
    }

    private func apply(_ operations: [LineEditOperation], to original: String, path: String) throws -> String {
        if let replacement = operations.first(where: { $0.operation == "replace_file" }) {
            guard operations.count == 1, let content = replacement.content else {
                throw DiffPatchError.invalidEdit("replace_file must be the only operation and requires content for '\(path)'.")
            }
            return content
        }

        let trailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }
        if original.isEmpty { lines.removeAll() }

        let prepared = try operations.map { operation in
            try prepare(operation, lineCount: lines.count, path: path)
        }
        for leftIndex in prepared.indices {
            for rightIndex in prepared.indices where rightIndex > leftIndex {
                guard !conflicts(prepared[leftIndex].range, prepared[rightIndex].range) else {
                    throw DiffPatchError.invalidEdit("Overlapping operations for '\(path)'.")
                }
            }
        }

        for edit in prepared.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            lines.replaceSubrange(edit.range, with: edit.replacement)
        }
        let result = lines.joined(separator: "\n")
        return trailingNewline ? result + "\n" : result
    }

    private func prepare(
        _ operation: LineEditOperation,
        lineCount: Int,
        path: String
    ) throws -> PreparedLineEdit {
        let contentLines = splitContent(operation.content ?? "")
        switch operation.operation {
        case "replace_lines", "delete_lines":
            guard let start = operation.startLine,
                  let end = operation.endLine ?? operation.startLine,
                  start >= 1, end >= start, end <= lineCount else {
                throw DiffPatchError.invalidEdit("Invalid line range for '\(path)'.")
            }
            if operation.operation == "replace_lines", operation.content == nil {
                throw DiffPatchError.invalidEdit("replace_lines requires content for '\(path)'.")
            }
            return PreparedLineEdit(
                range: (start - 1)..<end,
                replacement: operation.operation == "delete_lines" ? [] : contentLines
            )
        case "insert_before", "insert_after":
            guard let line = operation.startLine,
                  line >= 1, line <= lineCount,
                  operation.content != nil else {
                throw DiffPatchError.invalidEdit("Invalid insertion anchor for '\(path)'.")
            }
            let index = operation.operation == "insert_before" ? line - 1 : line
            return PreparedLineEdit(range: index..<index, replacement: contentLines)
        default:
            throw DiffPatchError.invalidEdit("Unknown operation '\(operation.operation)' for '\(path)'.")
        }
    }

    private func conflicts(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        if lhs.isEmpty && rhs.isEmpty { return lhs.lowerBound == rhs.lowerBound }
        if lhs.isEmpty { return lhs.lowerBound >= rhs.lowerBound && lhs.lowerBound <= rhs.upperBound }
        if rhs.isEmpty { return rhs.lowerBound >= lhs.lowerBound && rhs.lowerBound <= lhs.upperBound }
        return lhs.overlaps(rhs)
    }

    private func splitContent(_ content: String) -> [String] {
        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n") { lines.removeLast() }
        return content.isEmpty ? [] : lines
    }

    private func relativePath(for url: URL, workspaceRoot: String) throws -> String {
        let root = URL(fileURLWithPath: workspaceRoot).resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { throw DiffPatchError.unsafePath(path) }
        return String(path.dropFirst(root.count + 1))
    }

    private func makePatch(changes: [(path: String, old: String?, new: String)]) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Edits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var patches: [String] = []
        for (index, change) in changes.enumerated() {
            let oldURL = directory.appendingPathComponent("\(index)-old")
            let newURL = directory.appendingPathComponent("\(index)-new")
            try (change.old ?? "").write(to: oldURL, atomically: true, encoding: .utf8)
            try change.new.write(to: newURL, atomically: true, encoding: .utf8)
            patches.append(try unifiedDiff(
                oldURL: oldURL,
                newURL: newURL,
                oldLabel: change.old == nil ? "/dev/null" : "a/\(change.path)",
                newLabel: "b/\(change.path)",
                directory: directory,
                index: index
            ))
        }
        return patches.joined().trimmingCharacters(in: .newlines) + "\n"
    }

    private func unifiedDiff(
        oldURL: URL,
        newURL: URL,
        oldLabel: String,
        newLabel: String,
        directory: URL,
        index: Int
    ) throws -> String {
        let outputURL = directory.appendingPathComponent("\(index)-patch")
        let errorURL = directory.appendingPathComponent("\(index)-error")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = ["-u", "--label", oldLabel, "--label", newLabel, oldURL.path, newURL.path]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 1 else {
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            throw DiffPatchError.diffGenerationFailed(detail)
        }
        return try String(contentsOf: outputURL, encoding: .utf8)
    }
}
