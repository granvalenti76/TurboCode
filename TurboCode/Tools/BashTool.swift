import Foundation
import FoundationModels
import Darwin

// MARK: - Bash Tool

@Generable
struct BashArguments {
    /// Shell command to run from the workspace root.
    var command: String
    /// Timeout in seconds. Defaults to 30 and is clamped to 1...120.
    var timeoutSeconds: Int?
    /// Maximum combined output characters returned to the model. Defaults to 12000.
    var maxOutputCharacters: Int?
}

struct BashTool: Tool {
    typealias Arguments = BashArguments
    typealias Output = String

    let workspaceRoot: String
    let executionPolicy: ExecutionPolicy
    private let service = BashService()

    init(workspaceRoot: String, executionPolicy: ExecutionPolicy = ExecutionPolicy()) {
        self.workspaceRoot = workspaceRoot
        self.executionPolicy = executionPolicy
    }

    var name: String { "bash" }
    var description: String {
        """
        Run a zsh command from the workspace root. Use this for builds, tests, and
        precise inspection not covered by structured tools. Use git for every Git
        operation. Prefer read_file for source ranges and
        the available structured editing tool for text changes. The macOS process sandbox makes the workspace
        read-only; commands may write only to the private temporary directory exposed
        as TMPDIR. Output and execution time are bounded to keep model context small.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: BashArguments) async throws -> String {
        let command = arguments.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return "Error: command cannot be empty."
        }

        let timeout = min(
            max(arguments.timeoutSeconds ?? executionPolicy.defaultCommandTimeoutSeconds, 1),
            executionPolicy.maximumCommandTimeoutSeconds
        )
        let outputLimit = min(
            max(arguments.maxOutputCharacters ?? executionPolicy.maximumToolOutputCharacters, 1_000),
            executionPolicy.maximumToolOutputCharacters
        )

        return await service.run(
            command: command,
            workspaceRoot: workspaceRoot,
            timeoutSeconds: timeout,
            outputLimit: outputLimit,
            allowNetworkAccess: executionPolicy.allowNetworkAccess
        )
    }
}

// MARK: - Sandboxed Process Runner

private actor BashService {
    func run(
        command: String,
        workspaceRoot: String,
        timeoutSeconds: Int,
        outputLimit: Int,
        allowNetworkAccess: Bool
    ) -> String {
        let workspaceURL: URL
        do {
            workspaceURL = try WorkspacePathResolver.resolve(".", within: workspaceRoot)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "Error: Workspace directory does not exist at '\(workspaceURL.path)'."
        }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Bash-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = outputDirectory.appendingPathComponent("stderr.txt")

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        } catch {
            return "Error preparing command output: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            return "Error opening command output: \(error.localizedDescription)"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-p",
            sandboxProfile(
                workspacePath: workspaceURL.path,
                outputPath: outputDirectory.path,
                allowNetworkAccess: allowNetworkAccess
            ),
            "/bin/zsh",
            "-fc",
            command
        ]
        process.currentDirectoryURL = workspaceURL
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PWD": workspaceURL.path,
            "TMPDIR": outputDirectory.path,
            "GIT_CONFIG_GLOBAL": "/dev/null"
        ]) { _, new in new }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            return "Error launching command: \(error.localizedDescription)"
        }

        var timedOut = false
        while process.isRunning {
            if Date().timeIntervalSince(startedAt) >= Double(timeoutSeconds) {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if timedOut {
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        let stdout = readOutput(at: stdoutURL, limit: outputLimit / 2)
        let stderr = readOutput(at: stderrURL, limit: outputLimit / 2)
        let duration = Date().timeIntervalSince(startedAt)

        var sections = [
            "Working directory: \(workspaceURL.path)",
            "Exit code: \(process.terminationStatus)",
            String(format: "Duration: %.2fs", duration)
        ]
        if timedOut {
            sections.append("Timed out after \(timeoutSeconds)s.")
        }
        if !stdout.text.isEmpty {
            sections.append("STDOUT:\n\(stdout.text)\(stdout.truncated ? "\n... (stdout truncated)" : "")")
        }
        if !stderr.text.isEmpty {
            sections.append("STDERR:\n\(stderr.text)\(stderr.truncated ? "\n... (stderr truncated)" : "")")
        }
        if stdout.text.isEmpty && stderr.text.isEmpty {
            sections.append("(no output)")
        }
        return sections.joined(separator: "\n\n")
    }

    private func sandboxProfile(
        workspacePath: String,
        outputPath: String,
        allowNetworkAccess: Bool
    ) -> String {
        let workspace = profileEscaped(workspacePath)
        let output = profileEscaped(outputPath)
        let networkPolicy = allowNetworkAccess ? "" : "(deny network*)"
        return """
        (version 1)
        (allow default)
        \(networkPolicy)
        (deny file-read*
            (subpath "/Users")
            (subpath "/Volumes")
            (subpath "/Network")
            (subpath "/private/tmp"))
        (allow file-read* (subpath "\(workspace)"))
        (allow file-read* (subpath "\(output)"))
        (deny file-write*)
        (allow file-write* (subpath "\(output)"))
        (allow file-write-data (literal "/dev/null"))
        """
    }

    private func profileEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func readOutput(at url: URL, limit: Int) -> (text: String, truncated: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ("", false)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        let truncated = data.count > limit
        let visibleData = truncated ? data.prefix(limit) : data[...]
        return (
            String(decoding: visibleData, as: UTF8.self)
                .trimmingCharacters(in: .newlines),
            truncated
        )
    }
}
