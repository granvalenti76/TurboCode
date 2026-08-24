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
    let executionPolicy: ExecutionPolicy
    let taskScope: AgentTaskPathScope?
    private let requestApproval: @Sendable (PendingToolApproval) async -> String

    init(
        workspaceRoot: String,
        executionPolicy: ExecutionPolicy = ExecutionPolicy(),
        taskScope: AgentTaskPathScope? = nil,
        requestApproval: @escaping @Sendable (PendingToolApproval) async -> String = {
            await ToolApprovalRegistry.shared.request($0)
        }
    ) {
        self.workspaceRoot = workspaceRoot
        self.executionPolicy = executionPolicy
        self.taskScope = taskScope
        self.requestApproval = requestApproval
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(
            workspaceRoot: workspaceRoot,
            executionPolicy: executionPolicy,
            taskScope: scope,
            requestApproval: requestApproval
        )
    }

    var name: String { "read_file" }
    var description: String {
        """
        Read all or a precise inclusive line range from a UTF-8 text file. Paths outside
        the active workspace are available after host approval.
        Every returned source line is prefixed with its one-based line number, and the
        response reports a stable content revision, selected range, total line count, and
        approximate token cost. Large results stop on a line boundary and report the next
        range to request. Prefer small relevant ranges before calling the structured editor.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: ReadFileArguments) async throws -> String {
        let target: ResolvedWorkspacePath
        do {
            target = try WorkspacePathResolver.resolveForAccess(
                arguments.filePath,
                within: workspaceRoot
            )
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        if target.isInsideWorkspace {
            return read(arguments: arguments, fileURL: target.url)
        }

        return await WorkspaceAccessGate.shared.performExternalOperation(
            tool: name,
            operation: .read,
            workspaceRoot: workspaceRoot,
            targets: [target],
            requestApproval: requestApproval,
            action: { [self] in
                read(arguments: arguments, fileURL: target.url)
            }
        )
    }

    private func read(arguments: ReadFileArguments, fileURL: URL) -> String {
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
        return render(
            lines: lines,
            content: content,
            fileURL: fileURL,
            startLine: startLine,
            requestedEndLine: endLine,
            totalLines: totalLines
        )
    }

    /// Applies only an infrastructure ceiling: the model still chooses any
    /// range, while oversized responses expose an exact continuation point.
    private func render(
        lines: [String],
        content: String,
        fileURL: URL,
        startLine: Int,
        requestedEndLine: Int,
        totalLines: Int
    ) -> String {
        let outputLimit = max(executionPolicy.maximumToolOutputCharacters, 1_000)
        // Metadata includes a revision and continuation. Reserving its space
        // keeps truncation on source-line boundaries instead of cutting output.
        let bodyLimit = max(outputLimit - 640, 200)
        let numberWidth = String(totalLines).count
        var numberedLines: [String] = []
        var bodyCharacters = 0
        var renderedEndLine = startLine - 1
        var clippedOversizedLine = false

        for lineNumber in startLine...requestedEndLine {
            let number = String(format: "%*d", numberWidth, lineNumber)
            let rendered = "\(number) | \(lines[lineNumber - 1])"
            let addition = rendered.count + (numberedLines.isEmpty ? 0 : 1)
            guard bodyCharacters + addition <= bodyLimit else {
                if numberedLines.isEmpty {
                    // A minified file can contain a single enormous line. Give
                    // useful evidence while stating that this line is partial.
                    let suffix = " … [line clipped]"
                    let prefixLimit = max(bodyLimit - suffix.count, 1)
                    numberedLines.append(String(rendered.prefix(prefixLimit)) + suffix)
                    renderedEndLine = lineNumber
                    clippedOversizedLine = true
                }
                break
            }
            numberedLines.append(rendered)
            bodyCharacters += addition
            renderedEndLine = lineNumber
        }

        let body = numberedLines.joined(separator: "\n")
        let approximateTokens = Int(ceil(Double(body.utf8.count) / 3.2))
        let displayPath = concisePath(fileURL)
        var output = """
        File: \(displayPath)
        Revision: \(FileRevision.hash(content))
        Lines: \(startLine)-\(renderedEndLine) of \(totalLines)
        Approximate tokens: ~\(approximateTokens)

        \(body)
        """
        if clippedOversizedLine {
            output += "\n\nLine \(renderedEndLine) exceeded the output ceiling and was clipped."
        }
        if renderedEndLine < requestedEndLine {
            output += "\n\nOutput limited to \(outputLimit) characters. "
            output += "Continue with startLine \(renderedEndLine + 1) and endLine \(requestedEndLine)."
        }
        // The reserved metadata budget should make this a no-op. Keep the
        // final guard as a safety invariant for unusually long filesystem paths.
        return String(output.prefix(outputLimit))
    }

    private func concisePath(_ fileURL: URL) -> String {
        let rootURL = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        let path = fileURL.standardizedFileURL.path
        let rootPath = rootURL.path
        let relative = path.hasPrefix(rootPath + "/")
            ? String(path.dropFirst(rootPath.count + 1))
            : fileURL.lastPathComponent
        let singleLine = relative
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard singleLine.count > 180 else { return singleLine }
        return "…" + singleLine.suffix(179)
    }
}
