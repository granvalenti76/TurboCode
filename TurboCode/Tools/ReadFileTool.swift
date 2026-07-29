import Foundation
import FoundationModels

// MARK: - Read File Tool

/// Arguments for reading a file
@Generable
struct ReadFileArguments {
    /// Absolute or workspace-relative path to the file to read.
    var filePath: String
    /// First line to read, using one-based line numbers. Defaults to 1.
    var startLine: Int?
    /// Last line to read, inclusive. Defaults to the final line.
    var endLine: Int?
    /// Maximum number of lines to read. Kept for compatibility; endLine takes precedence.
    var limit: Int?
}

/// Reads a file from the local filesystem.
/// Corresponds to Kun's `read` tool.
struct ReadFileTool: Tool {
    typealias Arguments = ReadFileArguments
    typealias Output = String

    let workspaceRoot: String
    let taskScope: AgentTaskPathScope?

    init(workspaceRoot: String, taskScope: AgentTaskPathScope? = nil) {
        self.workspaceRoot = workspaceRoot
        self.taskScope = taskScope
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(workspaceRoot: workspaceRoot, taskScope: scope)
    }

    var name: String { "read_file" }
    var description: String {
        """
        Read all or a precise inclusive line range from a UTF-8 text file in the workspace.
        Every returned source line is prefixed with its one-based line number, and the
        response reports a stable content revision, selected range, and total line count.
        Prefer small ranges around relevant code before calling the structured editing tool.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: ReadFileArguments) async throws -> String {
        do {
            try taskScope?.validate(arguments.filePath)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        let fileURL: URL
        do {
            fileURL = try WorkspacePathResolver.resolve(arguments.filePath, within: workspaceRoot)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: fileURL.path) else {
            return "Error: File not found or not readable at path '\(arguments.filePath)'"
        }

        let content: String
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return "Error: Cannot read '\(arguments.filePath)' as UTF-8 text."
        }

        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n") {
            lines.removeLast()
        }
        if content.isEmpty {
            lines.removeAll()
        }
        lines = lines.map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }

        let totalLines = lines.count
        guard totalLines > 0 else {
            return "File: \(fileURL.path)\nLines: 0 total\n\n(empty file)"
        }

        let startLine = arguments.startLine ?? 1
        guard startLine >= 1 else {
            return "Error: startLine must be at least 1."
        }
        guard startLine <= totalLines else {
            return "Error: startLine \(startLine) is beyond the end of the file (\(totalLines) lines)."
        }

        let requestedEnd: Int
        if let endLine = arguments.endLine {
            guard endLine >= startLine else {
                return "Error: endLine must be greater than or equal to startLine."
            }
            requestedEnd = endLine
        } else if let limit = arguments.limit {
            guard limit > 0 else {
                return "Error: limit must be greater than 0."
            }
            requestedEnd = startLine - 1 + min(limit, totalLines)
        } else {
            requestedEnd = totalLines
        }

        let endLine = min(requestedEnd, totalLines)
        let numberWidth = String(totalLines).count
        let numberedLines = (startLine...endLine).map { lineNumber in
            let number = String(format: "%*d", numberWidth, lineNumber)
            return "\(number) | \(lines[lineNumber - 1])"
        }

        return """
        File: \(fileURL.path)
        Revision: \(FileRevision.hash(content))
        Lines: \(startLine)-\(endLine) of \(totalLines)

        \(numberedLines.joined(separator: "\n"))
        """
    }
}
