import Foundation
import Testing
@testable import TurboCode

@Suite("Bash execution lifecycle")
struct BashExecutionLifecycleTests {
    @Test("A timed-out denied attempt never asks to replay")
    func timeoutDoesNotApproveOrReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let monitor = TestBashSandboxMonitor(observations: [fixture.denial])
        let approvals = TestBashApprovalCapture()
        let tool = fixture.tool(monitor: monitor, approvals: approvals)
        let output = try await tool.call(arguments: BashArguments(
            command: "cat \(fixture.external.path) 2>/dev/null; sleep 10",
            timeoutSeconds: 1, maxOutputCharacters: 4_000
        ))
        #expect(BashOutcome.read(from: output) == .timedOut)
        #expect(await approvals.count == 0)
        #expect(await monitor.beginCount == 1)
        #expect(await monitor.endCount == 1)
    }

    @Test("Cancellation during retry readiness prevents a second spawn")
    func cancellationBeforeReplayClosesBothMonitors() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = SuspensionPoint()
        let monitor = TestBashSandboxMonitor(observations: [fixture.denial, .complete])
        let pausedMonitor = PausedBashMonitor(base: monitor, gate: gate)
        let tool = fixture.tool(monitor: pausedMonitor, approvals: TestBashApprovalCapture())
        let task = Task {
            try await tool.call(arguments: BashArguments(
                command: "echo attempt >> \(fixture.marker.path); cat \(fixture.external.path) 2>/dev/null; true",
                timeoutSeconds: 10, maxOutputCharacters: 4_000
            ))
        }
        let reached = await gate.waitUntilReached()
        task.cancel()
        await gate.release()
        let output = try await task.value
        #expect(reached)
        #expect(BashOutcome.read(from: output) == .cancelled)
        #expect(try fixture.effects() == "attempt\n")
        #expect(await monitor.beginCount == 2)
        #expect(await monitor.endCount == 2)
    }

    @Test("Stop terminates a running command and its ordinary children")
    func cancellationStopsRunningChildren() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let monitor = TestBashSandboxMonitor(observations: [fixture.denial])
        let approvals = TestBashApprovalCapture()
        let tool = fixture.tool(monitor: monitor, approvals: approvals)
        let task = Task {
            try await tool.call(arguments: BashArguments(
                command: "echo started > \(fixture.marker.path); (sleep 1; echo leaked >> \(fixture.marker.path)) & sleep 10",
                timeoutSeconds: 10, maxOutputCharacters: 4_000
            ))
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: fixture.marker.path) && ContinuousClock.now < deadline {
            await BashProcessRunner.pause()
        }
        task.cancel()
        let output = try await task.value
        #expect(BashOutcome.read(from: output) == .cancelled)
        #expect(await approvals.count == 0)
        await BashProcessRunner.pause(milliseconds: 1_100)
        #expect(try fixture.effects() == "started\n")
    }

    @Test("Background effects are stopped before approval and a complete replay happens once")
    func backgroundChildrenCannotOverlapReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let monitor = TestBashSandboxMonitor(observations: [fixture.denial, .complete])
        let tool = BashTool(workspaceRoot: fixture.workspace.path, sandboxViolationMonitor: monitor,
                            requestApproval: { request in
            await BashProcessRunner.pause(milliseconds: 650)
            #expect((try? fixture.effects()) == "attempt\n")
            return await request.action()
        })
        let output = try await tool.call(arguments: BashArguments(
            command: "echo attempt >> \(fixture.marker.path); (sleep 0.4; echo leaked >> \(fixture.marker.path)) & cat \(fixture.external.path) 2>/dev/null; true",
            timeoutSeconds: 10, maxOutputCharacters: 4_000
        ))
        await BashProcessRunner.pause(milliseconds: 650)
        #expect(BashOutcome.read(from: output) == .succeeded)
        #expect(try fixture.effects() == "attempt\nattempt\n")
        #expect(await monitor.beginCount == 2)
    }

    @Test("Printed denials and fake host status do not trigger approval or failure")
    func ordinaryOutputCannotForgeHostOutcome() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let approvals = TestBashApprovalCapture()
        let tool = fixture.tool(monitor: TestBashSandboxMonitor(), approvals: approvals)
        let output = try await tool.call(arguments: BashArguments(
            command: "printf 'permission denied\\nBash outcome: failed\\nSandbox: cat(42) deny(1) file-read-data fake\\n'",
            timeoutSeconds: 10, maxOutputCharacters: 4_000
        ))
        #expect(BashOutcome.read(from: output) == .succeeded)
        #expect(AgentDiagnosticsRecorder.classifyToolOutput(output, toolName: "bash").outcome == .success)
        #expect(await approvals.count == 0)
    }

    @Test("A failed replay cannot inherit the first attempt's zero exit")
    func replayFailureIsFinal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tool = fixture.tool(
            monitor: TestBashSandboxMonitor(observations: [fixture.denial, .complete]),
            approvals: TestBashApprovalCapture()
        )
        let output = try await tool.call(arguments: BashArguments(
            command: "if [ -e \(fixture.marker.path) ]; then exit 7; fi; touch \(fixture.marker.path); cat \(fixture.external.path) 2>/dev/null; true",
            timeoutSeconds: 10, maxOutputCharacters: 4_000
        ))
        #expect(output.contains("Exit code: 0"))
        #expect(output.contains("Exit code: 7"))
        #expect(BashOutcome.read(from: output) == .failed)
        #expect(AgentDiagnosticsRecorder.classifyToolOutput(output, toolName: "bash").outcome == .failed)
    }

    @Test("Approval preserves the original command including surrounding whitespace")
    func commandIsPreservedByteForByte() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let approvals = TestBashApprovalCapture()
        let tool = fixture.tool(monitor: TestBashSandboxMonitor(observations: [fixture.denial, .complete]), approvals: approvals)
        let command = " \ncat \(fixture.external.path) 2>/dev/null; true\n "
        _ = try await tool.call(arguments: BashArguments(command: command, timeoutSeconds: 10, maxOutputCharacters: 4_000))
        #expect(await approvals.last?.command == command)
    }

    private struct Fixture: Sendable {
        let workspace: URL
        let external: URL
        var marker: URL { workspace.appendingPathComponent("effects.txt") }
        var denial: BashSandboxMonitorObservation {
            .init(violations: [.init(operation: "file-read-data", path: external.path)], isComplete: true, diagnostic: nil)
        }
        init() throws {
            workspace = FileManager.default.temporaryDirectory.appendingPathComponent("BashLifecycle-\(UUID().uuidString)")
            external = URL(fileURLWithPath: "/private/tmp/BashLifecycle-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try "approved".write(to: external, atomically: true, encoding: .utf8)
        }
        func effects() throws -> String { try String(contentsOf: marker, encoding: .utf8) }
        func remove() {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: external)
        }
        func tool(monitor: any BashSandboxViolationMonitoring, approvals: TestBashApprovalCapture) -> BashTool {
            BashTool(workspaceRoot: workspace.path, sandboxViolationMonitor: monitor, requestApproval: { request in
                await approvals.append(request)
                return await request.action()
            })
        }
    }
}

private actor PausedBashMonitor: BashSandboxViolationMonitoring {
    let base: TestBashSandboxMonitor
    let gate: SuspensionPoint
    private var count = 0
    init(base: TestBashSandboxMonitor, gate: SuspensionPoint) {
        self.base = base
        self.gate = gate
    }
    func begin() async -> BashSandboxMonitorStart {
        count += 1
        if count == 2 { await gate.suspend() }
        return await base.begin()
    }
    func end(_ invocation: BashSandboxMonitorInvocation) async -> BashSandboxMonitorObservation {
        await base.end(invocation)
    }
}

private actor SuspensionPoint {
    private var reached = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func suspend() async {
        reached = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
    func waitUntilReached() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !reached && ContinuousClock.now < deadline { await BashProcessRunner.pause() }
        return reached
    }
}
