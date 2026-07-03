import Foundation
import FoundationModels
import LlamaModelExecutor

// MARK: - Bash / Command Execution Tool

/// Arguments for executing a shell command
@Generable
struct BashArguments {
    /// Shell command to execute
    var command: String
    /// Working directory for the command (optional, uses current directory if not specified)
    var workingDirectory: String?
    /// Timeout in seconds (optional, defaults to 30s)
    var timeout: Int?
}

/// Executes a shell command on the local machine.
/// Corresponds to Kun's `command_execution` and `background_shell` tools.
struct BashTool: Tool {
    typealias Arguments = BashArguments
    typealias Output = String

    var name: String { "bash" }
    var description: String { "Execute a shell command on the local machine. Returns stdout, stderr, and the exit code." }
    var includesSchemaInInstructions: Bool { false }

    func call(arguments: BashArguments) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", arguments.command]

        if let wd = arguments.workingDirectory, !wd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus

        var result = "Exit code: \(exitCode)"
        if !stdout.isEmpty { result += "\n\nstdout:\n\(stdout)" }
        if !stderr.isEmpty { result += "\n\nstderr:\n\(stderr)" }

        return result
    }
}
