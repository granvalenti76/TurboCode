import Foundation
import Testing
@testable import TurboCode

@Suite("Bash sandbox violation monitor")
struct BashSandboxViolationMonitorTests {
    @Test("Parser attributes chunked filesystem events and ignores ordinary text")
    func parserAttributesOnlyCorrelatedKernelEvents() throws {
        let tag = "TEST_BASH_TAG"
        let event = try logRecord(
            senderImagePath: BashSandboxLogParser.sandboxSenderImagePath,
            processImagePath: "/kernel",
            message: "Sandbox: cat(42) deny(1) file-read-data /private/tmp/file with spaces\n\(tag)"
        )
        let ordinaryText = try logRecord(
            senderImagePath: "/usr/bin/log",
            processImagePath: "/usr/bin/log",
            message: "Sandbox: cat(42) deny(1) file-read-data /private/tmp/fake\n\(tag)"
        )
        let networkEvent = try logRecord(
            senderImagePath: BashSandboxLogParser.sandboxSenderImagePath,
            processImagePath: "/kernel",
            message: "Sandbox: cat(42) deny(1) network-outbound example.test\n\(tag)"
        )

        var parser = BashSandboxLogParser()
        let stream = event + Data([0x0A]) + event + Data([0x0A]) + ordinaryText + Data([0x0A]) + networkEvent + Data([0x0A])
        let midpoint = stream.count / 2
        parser.append(Data(stream[..<midpoint]), tag: tag)
        parser.append(Data(stream[midpoint...]), tag: tag)
        parser.finish(tag: tag)

        #expect(parser.problems.isEmpty)
        #expect(parser.violations == [
            BashSandboxViolation(
                operation: "file-read-data",
                path: "/private/tmp/file with spaces"
            )
        ])
    }

    @Test("Bash requests one approval even when the shell exits successfully")
    func bashUsesObservedViolationInsteadOfExitCodeOrStderr() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-BashMonitor-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let externalFile = URL(fileURLWithPath: "/private/tmp/TurboCode-BashMonitor-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalFile)
        }

        let monitor = TestBashSandboxMonitor(observations: [
            BashSandboxMonitorObservation(
                violations: [BashSandboxViolation(operation: "file-write-data", path: externalFile.path)],
                isComplete: true,
                diagnostic: nil
            ),
            .complete
        ])
        let approvals = TestBashApprovalCapture()
        let tool = BashTool(
            workspaceRoot: workspace.path,
            sdkRoot: root.appendingPathComponent("sdk", isDirectory: true).path,
            homeDirectory: root.appendingPathComponent("home", isDirectory: true).path,
            sandboxViolationMonitor: monitor,
            requestApproval: { request in
                await approvals.append(request)
                return await request.action()
            }
        )
        let command = "printf approved > \(externalFile.path) 2>/dev/null; echo \"exit: $?\""

        let output = try await tool.call(
            arguments: BashArguments(command: command, timeoutSeconds: 10, maxOutputCharacters: 4_000)
        )

        #expect(output.contains("First attempt:"))
        #expect(output.contains("Approved complete rerun:"))
        #expect(output.contains("Exit code: 0"))
        #expect(await approvals.count == 1)
        #expect(await approvals.last?.command == command)
        #expect(await approvals.last?.path == externalFile.path)
        #expect(await approvals.last?.summary.contains("rerun this complete command") == true)
        #expect(await monitor.beginCount == 2)
        #expect(await monitor.endCount == 2)
        #expect(try String(contentsOf: externalFile, encoding: .utf8) == "approved")
    }

    @Test("A rejected approval never reruns the command")
    func rejectionDoesNotRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-BashReject-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let externalFile = URL(fileURLWithPath: "/private/tmp/TurboCode-BashReject-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalFile)
        }

        let monitor = TestBashSandboxMonitor(observations: [
            BashSandboxMonitorObservation(
                violations: [BashSandboxViolation(operation: "file-write-data", path: externalFile.path)],
                isComplete: true,
                diagnostic: nil
            )
        ])
        let approvals = TestBashApprovalCapture()
        let tool = BashTool(
            workspaceRoot: workspace.path,
            sandboxViolationMonitor: monitor,
            requestApproval: { request in
                await approvals.append(request)
                return "Action cancelled by the user."
            }
        )

        let output = try await tool.call(
            arguments: BashArguments(
                command: "printf should-not-run > \(externalFile.path) 2>/dev/null; echo \"exit: $?\"",
                timeoutSeconds: 10,
                maxOutputCharacters: 4_000
            )
        )

        #expect(output.contains("complete command was not rerun"))
        #expect(!output.contains("Approved complete rerun:"))
        #expect(await approvals.count == 1)
        #expect(await monitor.beginCount == 1)
        #expect(await monitor.endCount == 1)
        #expect(!FileManager.default.fileExists(atPath: externalFile.path))
    }

    @Test("Unavailable diagnostics prevent command execution")
    func unavailableMonitorStopsBeforeExecution() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-BashUnavailable-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let marker = workspace.appendingPathComponent("marker.txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tool = BashTool(
            workspaceRoot: workspace.path,
            sandboxViolationMonitor: TestBashSandboxMonitor(start: .unavailable("test unavailable"))
        )
        let output = try await tool.call(
            arguments: BashArguments(command: "touch \(marker.path)", timeoutSeconds: 10, maxOutputCharacters: 4_000)
        )

        #expect(output.contains("sandbox diagnostics unavailable"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Unexpected collector termination survives intentional final cleanup")
    func unexpectedCollectorExitIsLatched() {
        let state = BashSandboxLogState()
        state.markProcessEnded()
        state.requestStop(wasRunning: false)
        let observation = state.observation(tag: "TEST")
        #expect(!observation.isComplete)
        #expect(observation.diagnostic?.contains("ended before") == true)
    }

    @Test("A failed delivery window retains events but is explicitly incomplete")
    func incompleteWindowRetainsObservedDenials() throws {
        let tag = "TEST"
        let state = BashSandboxLogState()
        state.append(try logRecord(
            senderImagePath: BashSandboxLogParser.sandboxSenderImagePath,
            processImagePath: "/kernel",
            message: "Sandbox: cat(42) deny(1) file-read-data /private/tmp/test\n\(tag)"
        ) + Data([10]), tag: tag)
        state.requestStop(wasRunning: true)
        state.markProcessEnded()
        let observation = state.observation(tag: tag, diagnostic: "Delivery window exhausted.")
        #expect(!observation.isComplete)
        #expect(observation.violations.count == 1)
        #expect(observation.diagnostic == "Delivery window exhausted.")
    }

    @Test("Readiness and final markers cannot contaminate invocation events")
    func markersAndUnrelatedInvocationsAreSeparated() throws {
        let state = BashSandboxLogState()
        for tag in ["TEST_READY", "UNRELATED", "TEST_FENCE"] {
            let data = try logRecord(
                senderImagePath: BashSandboxLogParser.sandboxSenderImagePath,
                processImagePath: "/kernel",
                message: "Sandbox: stat(42) deny(1) file-read-metadata /private/tmp/probe\n\(tag)"
            ) + Data([10])
            for byte in data { state.append(Data([byte]), tag: "TEST") }
        }
        #expect(state.sawReady)
        #expect(state.sawFence)
        #expect(state.observation(tag: "TEST").violations.isEmpty)
    }

    @Test("Starting a process without sandbox event delivery is not readiness")
    func runningCollectorWithoutEventsIsUnavailable() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // exec keeps the fixture a single process owned by the monitor.
        try "#!/bin/zsh\nexec /bin/sleep 30\n".write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let monitor = BashSandboxViolationMonitor(logExecutable: fixture.path)
        let start = ContinuousClock.now
        guard case .unavailable = await monitor.begin() else {
            Issue.record("A live process without a kernel event must not be considered ready.")
            return
        }
        #expect(start.duration(to: .now) < .seconds(6))
    }

    private func logRecord(
        senderImagePath: String,
        processImagePath: String,
        message: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "senderImagePath": senderImagePath,
            "processImagePath": processImagePath,
            "eventMessage": message
        ])
    }
}

/// A lock-backed fake keeps observations deterministic across tool actors and
/// allows cancellation tests to suspend a separate wrapper at an exact boundary.
nonisolated final class TestBashSandboxMonitor: BashSandboxViolationMonitoring, @unchecked Sendable {
    enum StartMode: Sendable {
        case ready
        case unavailable(String)
    }
    private let lock = NSLock()
    private var observations: [BashSandboxMonitorObservation]
    private let startMode: StartMode
    private var starts = 0
    private var ends = 0
    var beginCount: Int { get async { lock.withLock { starts } } }
    var endCount: Int { get async { lock.withLock { ends } } }

    init(observations: [BashSandboxMonitorObservation] = [], start: StartMode = .ready) {
        self.observations = observations
        self.startMode = start
    }
    func begin() async -> BashSandboxMonitorStart {
        lock.withLock {
            starts += 1
            switch startMode {
            case .ready:
                return .ready(BashSandboxMonitorInvocation(id: UUID(), tag: "TEST_BASH_\(starts)"))
            case .unavailable(let reason):
                return .unavailable(reason)
            }
        }
    }
    func end(_ invocation: BashSandboxMonitorInvocation) async -> BashSandboxMonitorObservation {
        lock.withLock {
            ends += 1
            return observations.isEmpty ? .complete : observations.removeFirst()
        }
    }
}

actor TestBashApprovalCapture {
    private(set) var requests: [PendingToolApproval] = []

    func append(_ request: PendingToolApproval) {
        requests.append(request)
    }

    var count: Int { requests.count }
    var last: PendingToolApproval? { requests.last }
}

extension BashSandboxMonitorObservation {
    static var complete: Self {
        Self(violations: [], isComplete: true, diagnostic: nil)
    }
}
