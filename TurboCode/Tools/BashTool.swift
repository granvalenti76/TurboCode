import Foundation
import FoundationModels

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
        await runBash(
            command: arguments.command,
            workingDirectory: arguments.workingDirectory,
            timeout: arguments.timeout ?? 30
        )
    }

    // MARK: - Private

    private func runBash(command: String, workingDirectory: String?, timeout: Int) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", command]

                if let wd = workingDirectory, !wd.isEmpty {
                    process.currentDirectoryURL = URL(fileURLWithPath: wd)
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Timeout handling
                let timeoutWorkItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }

                do {
                    try process.run()

                    // Schedule timeout if > 0
                    if timeout > 0 {
                        DispatchQueue.global().asyncAfter(
                            deadline: .now() + .seconds(timeout),
                            execute: timeoutWorkItem
                        )
                    }

                    process.waitUntilExit()
                    timeoutWorkItem.cancel()  // cancel timeout if process finished in time

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    let exitCode = process.terminationStatus

                    let wasTimedOut = exitCode == SIGTERM || (exitCode == -1 && !process.isRunning)
                    var result = wasTimedOut
                        ? "Command timed out after \(timeout)s"
                        : "Exit code: \(exitCode)"

                    if !stdout.isEmpty {
                        result += "\n\nstdout:\n\(stdout)"
                    }
                    if !stderr.isEmpty {
                        result += "\n\nstderr:\n\(stderr)"
                    }

                    continuation.resume(returning: result)
                } catch {
                    timeoutWorkItem.cancel()
                    continuation.resume(returning: "Error: \(error.localizedDescription)")
                }
            }
        }
    }
}
