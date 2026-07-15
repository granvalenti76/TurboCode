import Darwin
import Foundation

/// Direct argument-based process execution for Apple developer tools. No model
/// input is ever evaluated by a shell.
actor XcodeCommandRunner {
    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        timeoutSeconds: Int,
        outputCharacterLimit: Int = 1_000_000
    ) -> Result<XcodeCommandResult, XcodeProjectError> {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Xcode-Output-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = outputDirectory.appendingPathComponent("stderr.txt")

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            return .failure(.launchFailed("Unable to prepare command output."))
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CI": "1",
            "NSUnbufferedIO": "YES"
        ]) { _, new in new }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            return .failure(.launchFailed(error.localizedDescription))
        }

        var timedOut = false
        var cancelled = false
        while process.isRunning {
            if Task.isCancelled {
                cancelled = true
                process.terminate()
                break
            } else if Date().timeIntervalSince(startedAt) >= Double(timeoutSeconds) {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if timedOut || cancelled {
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        return .success(
            XcodeCommandResult(
                exitCode: process.terminationStatus,
                stdout: readText(at: stdoutURL, limit: outputCharacterLimit),
                stderr: readText(at: stderrURL, limit: outputCharacterLimit),
                duration: Date().timeIntervalSince(startedAt),
                timedOut: timedOut,
                cancelled: cancelled
            )
        )
    }

    private func readText(at url: URL, limit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        if data.count <= limit { return String(decoding: data, as: UTF8.self) }

        let headCount = limit / 3
        let tailCount = limit - headCount
        return String(decoding: data.prefix(headCount), as: UTF8.self)
            + "\n… command output compacted by TurboCode …\n"
            + String(decoding: data.suffix(tailCount), as: UTF8.self)
    }
}
