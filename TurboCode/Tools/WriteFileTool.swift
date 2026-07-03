import Foundation
import FoundationModels
import LlamaModelExecutor

// MARK: - Write File Tool

/// Arguments for writing to a file
@Generable
struct WriteFileArguments {
    /// Absolute path to the file to write
    var filePath: String
    /// Content to write to the file
    var content: String
    /// If true, append to the file instead of overwriting (optional, defaults to false)
    var append: Bool?
}

/// Writes content to a file on the local filesystem.
/// Creates parent directories if they don't exist.
struct WriteFileTool: Tool {
    typealias Arguments = WriteFileArguments
    typealias Output = String

    var name: String { "write_file" }
    var description: String { "Write or append content to a file on the local filesystem. Creates parent directories if they don't exist." }
    var includesSchemaInInstructions: Bool { false }

    func call(arguments: WriteFileArguments) async throws -> String {
        let url = URL(fileURLWithPath: arguments.filePath)
        let parentDir = url.deletingLastPathComponent()

        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        if arguments.append == true {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(arguments.content.utf8))
            try handle.close()
            return "Successfully appended \(arguments.content.utf8.count) bytes to '\(arguments.filePath)'"
        } else {
            try arguments.content.write(toFile: arguments.filePath, atomically: true, encoding: .utf8)
            return "Successfully wrote \(arguments.content.utf8.count) bytes to '\(arguments.filePath)'"
        }
    }
}
