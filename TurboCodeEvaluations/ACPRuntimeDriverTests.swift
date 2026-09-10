import Foundation
import Testing
@testable import TurboCode

@Suite("ACP runtime driver")
struct ACPRuntimeDriverTests {
    @Test("sessions retain their own workspace and turn identity")
    func sessionIsolation() async throws {
        let runtime = ACPTestApplicationRuntime()
        let driver = ACPRuntimeDriver(runtime: runtime)

        let first = try await driver.createSession(cwd: "/tmp/one", mcpServers: [])
        let second = try await driver.createSession(cwd: "/tmp/two", mcpServers: [])
        _ = try await driver.prompt(sessionID: first, prompt: [], updates: ACPUpdateChannel())
        _ = try await driver.prompt(sessionID: second, prompt: [], updates: ACPUpdateChannel())

        let turns = await runtime.recordedTurns()
        #expect(turns.count == 2)
        #expect(Set(turns.map(\.cwd)) == Set(["/tmp/one", "/tmp/two"]))
        #expect(turns.contains { $0.sessionID == first && $0.cwd == "/tmp/one" })
        #expect(turns.contains { $0.sessionID == second && $0.cwd == "/tmp/two" })
        #expect(turns[0].turnID != turns[1].turnID)
    }

    @Test("unknown sessions fail closed")
    func unknownSession() async {
        let driver = ACPRuntimeDriver(runtime: ACPTestApplicationRuntime())
        do {
            _ = try await driver.prompt(
                sessionID: "missing",
                prompt: [],
                updates: ACPUpdateChannel()
            )
            Issue.record("Expected an unknown ACP session to fail.")
        } catch let error as ACPApplicationRuntimeError {
            #expect(error == .sessionNotFound("missing"))
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }
}

private actor ACPTestApplicationRuntimeState {
    var turns: [ACPApplicationTurn] = []

    func append(_ turn: ACPApplicationTurn) {
        turns.append(turn)
    }

    func snapshot() -> [ACPApplicationTurn] {
        turns
    }
}

private final class ACPTestApplicationRuntime: ACPApplicationRuntime, @unchecked Sendable {
    private let state = ACPTestApplicationRuntimeState()

    nonisolated func prepareSession(
        sessionID: String,
        cwd: String,
        mcpServers: [MCPJSONValue]
    ) async throws {}

    nonisolated func run(
        turn: ACPApplicationTurn,
        updates: ACPUpdateChannel
    ) async throws -> ACPStopReason {
        await state.append(turn)
        return .endTurn
    }

    nonisolated func cancel(sessionID: String) async {}

    nonisolated func recordedTurns() async -> [ACPApplicationTurn] {
        await state.snapshot()
    }
}
