import Foundation
import Darwin

/// Identifies one Bash attempt in the macOS sandbox log without including the
/// command, a secret, or a path in the profile message.
nonisolated struct BashSandboxMonitorInvocation: Sendable, Equatable {
    let id: UUID
    let tag: String
}

nonisolated enum BashSandboxMonitorStart: Sendable {
    case ready(BashSandboxMonitorInvocation)
    case unavailable(String)
}

nonisolated struct BashSandboxViolation: Sendable, Equatable {
    let operation: String
    let path: String
}

nonisolated struct BashSandboxMonitorObservation: Sendable, Equatable {
    let violations: [BashSandboxViolation]
    let isComplete: Bool
    let diagnostic: String?
}

/// The host-side log channel used by Bash. It is deliberately injectable so
/// command execution tests can prove attribution without depending on the
/// timing or permissions of a live macOS log stream.
nonisolated protocol BashSandboxViolationMonitoring: Sendable {
    func begin() async -> BashSandboxMonitorStart
    func end(_ invocation: BashSandboxMonitorInvocation) async -> BashSandboxMonitorObservation
}

/// Parses one NDJSON record at a time. Keeping the byte buffer here matters:
/// `log stream` may split a JSON record across pipe reads, while an event's
/// message may itself contain escaped newlines.
nonisolated struct BashSandboxLogParser: Sendable {
    private struct LogRecord: Decodable {
        let senderImagePath: String?
        let processImagePath: String?
        let eventMessage: String?
    }

    static let sandboxSenderImagePath = "/System/Library/Extensions/Sandbox.kext/Contents/MacOS/Sandbox"

    private var buffer = Data()
    private(set) var violations: [BashSandboxViolation] = []
    private(set) var problems: [String] = []

    mutating func append(_ data: Data, tag: String) {
        guard !data.isEmpty else { return }
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            parse(line, tag: tag)
        }

        if buffer.count > 256_000 {
            recordProblem("The sandbox log record exceeded the bounded parser buffer.")
            buffer.removeAll(keepingCapacity: true)
        }
    }

    mutating func finish(tag: String) {
        if !buffer.isEmpty {
            let finalRecord = buffer
            buffer.removeAll(keepingCapacity: true)
            parse(finalRecord, tag: tag)
        }
    }

    var hasUnconsumedData: Bool { !buffer.isEmpty }

    private mutating func parse(_ data: Data, tag: String) {
        guard !data.isEmpty else { return }
        guard data.count <= 256_000 else {
            recordProblem("The sandbox log record exceeded the bounded parser buffer.")
            return
        }
        guard let record = try? JSONDecoder().decode(LogRecord.self, from: data) else {
            recordProblem("A sandbox log record could not be decoded.")
            return
        }

        // A model command can print text that looks like a sandbox event. The
        // kernel/Sandbox.kext provenance and the exact per-invocation tag are
        // both required before a record can affect authorization.
        guard record.senderImagePath == Self.sandboxSenderImagePath,
              record.processImagePath == "/kernel",
              let message = record.eventMessage else { return }

        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == tag }),
              let denialLine = lines.first(where: {
                  $0.hasPrefix("Sandbox:") && $0.contains(" deny(")
              }) else { return }

        let fields = denialLine.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard fields.count >= 4,
              fields[0] == "Sandbox:",
              fields[2].hasPrefix("deny("),
              fields[3].hasPrefix("file-") else {
            return
        }

        let path = fields.count == 5
            ? String(fields[4])
            : "unspecified filesystem target"
        let violation = BashSandboxViolation(
            operation: String(fields[3]),
            path: path
        )
        guard !violations.contains(violation) else { return }
        if violations.count < 32 {
            violations.append(violation)
        } else {
            recordProblem("The sandbox violation list reached its bounded capacity.")
        }
    }

    private mutating func recordProblem(_ problem: String) {
        guard problems.count < 4 else { return }
        problems.append(problem)
    }
}

/// Each stream proves readiness with an actual tagged sandbox denial before
/// accepting a user command. A second marker and a bounded tail window drain
/// delayed events after exit. Log delivery is diagnostic, not a syscall barrier.
actor BashSandboxViolationMonitor: BashSandboxViolationMonitoring {
    static let shared = BashSandboxViolationMonitor()
    private let logExecutable: String
    private var sessions: [UUID: LiveLogSession] = [:]

    init(logExecutable: String = "/usr/bin/log") {
        self.logExecutable = logExecutable
    }

    func begin() async -> BashSandboxMonitorStart {
        guard !Task.isCancelled else { return .unavailable("Command cancelled.") }
        let invocation = BashSandboxMonitorInvocation(
            id: UUID(), tag: "TURBOCODE_BASH_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        )
        let session: LiveLogSession
        do {
            session = try LiveLogSession(executable: logExecutable, tag: invocation.tag)
        } catch {
            return .unavailable("Unable to start sandbox diagnostics: \(error.localizedDescription)")
        }
        // Successful `log show` or Process.run() says nothing about the stream's
        // subscription. Repeat only our harmless probe until its event arrives.
        let deadline = ContinuousClock.now + .seconds(3)
        var probeFailure: String?
        while !session.state.sawReady && session.isRunning && !Task.isCancelled
                && ContinuousClock.now < deadline {
            probeFailure = await session.emitMarker(suffix: "_READY")
            if probeFailure != nil { break }
            await BashProcessRunner.pause(milliseconds: 75)
        }
        guard session.state.sawReady, session.isRunning, !Task.isCancelled else {
            _ = await session.stop(diagnostic: "The sandbox log stream did not deliver its readiness event.")
            return .unavailable(Task.isCancelled
                ? "Command cancelled."
                : probeFailure ?? "The sandbox log stream did not deliver its readiness event; command was not started.")
        }
        sessions[invocation.id] = session
        return .ready(invocation)
    }

    func end(_ invocation: BashSandboxMonitorInvocation) async -> BashSandboxMonitorObservation {
        guard let session = sessions.removeValue(forKey: invocation.id) else {
            return BashSandboxMonitorObservation(
                violations: [], isComplete: false, diagnostic: "The sandbox log session was not found."
            )
        }
        // The marker exercises the same kernel source and subscription. Keep
        // collecting through a bounded tail; do not kill log at shell exit.
        // Cancellation skips the extra probes but still owns and closes log.
        let deadline = ContinuousClock.now + .seconds(1)
        while !session.state.sawFence && session.isRunning && !Task.isCancelled
                && ContinuousClock.now < deadline {
            if await session.emitMarker(suffix: "_FENCE") != nil { break }
            await BashProcessRunner.pause(milliseconds: 75)
        }
        if session.state.sawFence && !Task.isCancelled {
            await BashProcessRunner.pause(milliseconds: 100)
        }
        let diagnostic = session.state.sawFence ? nil
            : "The final sandbox event collection window ended without a delivery marker."
        return await session.stop(diagnostic: diagnostic)
    }
}

/// Callbacks only append bytes under this lock. Unexpected termination is
/// latched when it happens; a later intentional stop must never erase it.
nonisolated final class BashSandboxLogState: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = BashSandboxLogParser()
    private var readyParser = BashSandboxLogParser()
    private var fenceParser = BashSandboxLogParser()
    private var unexpectedEnd = false
    private var stopRequested = false

    func append(_ data: Data, tag: String) {
        lock.withLock {
            parser.append(data, tag: tag)
            readyParser.append(data, tag: tag + "_READY")
            fenceParser.append(data, tag: tag + "_FENCE")
        }
    }

    var sawReady: Bool { lock.withLock { !readyParser.violations.isEmpty } }
    var sawFence: Bool { lock.withLock { !fenceParser.violations.isEmpty } }

    func markProcessEnded() {
        lock.withLock { if !stopRequested { unexpectedEnd = true } }
    }

    func requestStop(wasRunning: Bool) {
        lock.withLock {
            if !wasRunning { unexpectedEnd = true }
            stopRequested = true
        }
    }

    func observation(tag: String, diagnostic: String? = nil) -> BashSandboxMonitorObservation {
        lock.withLock {
            parser.finish(tag: tag)
            let problem = unexpectedEnd
                ? "The macOS sandbox log stream ended before collection finished."
                : diagnostic ?? parser.problems.first
            return BashSandboxMonitorObservation(
                violations: parser.violations, isComplete: problem == nil, diagnostic: problem
            )
        }
    }
}

/// Owned by the monitor actor; only `state` crosses into pipe callbacks.
/// Foundation process I/O and bounded async waits never run on MainActor.
nonisolated private final class LiveLogSession: @unchecked Sendable {
    private let process: Process
    private let reader: BashSandboxLogReader
    private let tag: String
    private let fixture: URL
    let state = BashSandboxLogState()
    var isRunning: Bool { process.isRunning }

    init(executable: String, tag: String) throws {
        self.tag = tag
        // Use a real data read outside the per-user temporary directory.
        // Metadata-only probes in that directory can be implicitly permitted
        // by macOS and therefore do not establish sandbox-log readiness.
        fixture = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("TurboCode-SandboxProbe-\(UUID().uuidString)")
        try Data("probe".utf8).write(to: fixture, options: .withoutOverwriting)
        let pipe = Pipe()
        process = Process()
        reader = BashSandboxLogReader(handle: pipe.fileHandleForReading, state: state, tag: tag)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "stream", "--style", "ndjson", "--type", "log",
            "--predicate", "senderImagePath == \"\(BashSandboxLogParser.sandboxSenderImagePath)\" AND eventMessage CONTAINS[c] \"\(tag)\""
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [state] _ in state.markProcessEnded() }
        do {
            try process.run()
        } catch {
            _ = reader.close()
            try? FileManager.default.removeItem(at: fixture)
            throw error
        }
    }

    func emitMarker(suffix: String) async -> String? {
        // Process accepts Foundation's virtual null handle, but posix_spawn
        // needs a real descriptor. Keep it open through the async probe.
        let sink: FileHandle
        do { sink = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null")) }
        catch { return "Unable to open sandbox probe output: \(error.localizedDescription)" }
        defer { try? sink.close() }
        let path = fixture.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let profile = "(version 1)(allow default)(deny file-read* (literal \"\(path)\") (with message \"\(tag + suffix)\"))"
        let result = await BashProcessRunner.run(
            executable: "/usr/bin/sandbox-exec",
            arguments: ["-p", profile, "/bin/cat", fixture.path],
            environment: ProcessInfo.processInfo.environment,
            directory: fixture.deletingLastPathComponent().path,
            stdout: sink.fileDescriptor, stderr: sink.fileDescriptor,
            timeout: .milliseconds(300)
        )
        if let error = result.error { return "Sandbox readiness probe failed: \(error)" }
        if !result.canRerun { return "Sandbox readiness probe was interrupted or could not be cleaned up." }
        if result.exitCode == 0 { return "The sandbox readiness probe was unexpectedly allowed." }
        return nil
    }

    func stop(diagnostic: String?) async -> BashSandboxMonitorObservation {
        let wasRunning = process.isRunning
        state.requestStop(wasRunning: wasRunning)
        if wasRunning {
            process.terminate()
            let deadline = ContinuousClock.now + .milliseconds(300)
            while process.isRunning && ContinuousClock.now < deadline { await BashProcessRunner.pause() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let deadline = ContinuousClock.now + .seconds(1)
        while process.isRunning && ContinuousClock.now < deadline { await BashProcessRunner.pause() }
        let drainComplete = reader.close()
        try? FileManager.default.removeItem(at: fixture)
        let problem = process.isRunning ? "The sandbox collector could not be stopped."
            : !drainComplete ? "The final sandbox log drain exceeded its bounded capacity."
            : diagnostic
        return state.observation(tag: tag, diagnostic: problem)
    }
}

/// Serializes pipe reads with close so a callback cannot append a late chunk
/// after observation() or read a descriptor that has already been reused.
nonisolated private final class BashSandboxLogReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let state: BashSandboxLogState
    private let tag: String
    private var closed = false

    init(handle: FileHandle, state: BashSandboxLogState, tag: String) {
        self.handle = handle
        self.state = state
        self.tag = tag
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        handle.readabilityHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { if !self.closed { _ = self.drain() } }
        }
    }

    func close() -> Bool {
        handle.readabilityHandler = nil
        return lock.withLock {
            guard !closed else { return true }
            let complete = drain()
            closed = true
            try? handle.close()
            return complete
        }
    }

    private func drain() -> Bool {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var budget = 256_000
        while budget > 0 {
            let count = read(handle.fileDescriptor, &bytes, min(bytes.count, budget))
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return count == 0 || errno == EAGAIN }
            state.append(Data(bytes.prefix(count)), tag: tag)
            budget -= count
        }
        return false
    }
}
