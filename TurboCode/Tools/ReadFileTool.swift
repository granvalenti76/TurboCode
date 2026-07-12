import Foundation
import FoundationModels

// MARK: - Read File Tool

/// Arguments for reading a file
@Generable
struct ReadFileArguments {
    /// Absolute path to the file to read
    var filePath: String
    /// Maximum number of lines to read (optional, reads all lines if not specified)
    var limit: Int?
}

/// Reads a file from the local filesystem.
/// Corresponds to Kun's `read` tool.
struct ReadFileTool: Tool {
    typealias Arguments = ReadFileArguments
    typealias Output = String

    var name: String { "read_file" }
    var description: String { "Read the contents of a file from the local filesystem. Returns the file content or an error message if the file doesn't exist." }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: ReadFileArguments) async throws -> String {
        guard FileManager.default.isReadableFile(atPath: arguments.filePath) else {
            return "Error: File not found or not readable at path '\(arguments.filePath)'"
        }

        let content = try String(contentsOfFile: arguments.filePath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        if let limit = arguments.limit, limit > 0, lines.count > limit {
            let truncated = lines.prefix(limit).joined(separator: "\n")
            return truncated + "\n\n... (truncated, \(lines.count - limit) more lines)"
        }

        return content
    }
}
