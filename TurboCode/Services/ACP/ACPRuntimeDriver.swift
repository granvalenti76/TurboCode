import Foundation

/// Maps ACP session identity to the shared, UI-independent application runtime.
/// Session IDs are generated here so no global active-project state can leak
/// between two independent Xcode conversations.
nonisolated final class ACPRuntimeDriver: ACPAgentDriver, @unchecked Sendable {
    private let runtime: any ACPApplicationRuntime
    private let state = State()

    init(runtime: any ACPApplicationRuntime) {
        self.runtime = runtime
    }

    nonisolated func createSession(
        cwd: String,
        mcpServers: [MCPJSONValue]
    ) async throws -> String {
        let sessionID = "acp-\(UUID().uuidString)"
        try await runtime.prepareSession(
            sessionID: sessionID,
            cwd: cwd,
            mcpServers: mcpServers
        )
        await state.insert(sessionID: sessionID, cwd: cwd)
        return sessionID
    }

    nonisolated func prompt(
        sessionID: String,
        prompt: [MCPJSONValue],
        updates: ACPUpdateChannel
    ) async throws -> ACPStopReason {
        try await self.prompt(
            sessionID: sessionID,
            prompt: prompt,
            updates: updates,
            requestPermission: { _ in ACPPermissionOutcome.reject }
        )
    }

    nonisolated func prompt(
        sessionID: String,
        prompt: [MCPJSONValue],
        updates: ACPUpdateChannel,
        requestPermission: @escaping ACPPermissionHandler
    ) async throws -> ACPStopReason {
        guard let cwd = await state.cwd(for: sessionID) else {
            throw ACPApplicationRuntimeError.sessionNotFound(sessionID)
        }
        return try await runtime.run(
            turn: ACPApplicationTurn(
                sessionID: sessionID,
                turnID: TurnID(),
                cwd: cwd,
                prompt: prompt
            ),
            updates: updates,
            requestPermission: requestPermission
        )
    }

    nonisolated func cancel(sessionID: String) async {
        await runtime.cancel(sessionID: sessionID)
    }

    nonisolated func shutdown() async {
        await runtime.shutdown()
    }

    nonisolated func configurationOptions(
        sessionID: String
    ) async throws -> [ACPConfigOption] {
        try await runtime.configurationOptions(sessionID: sessionID)
    }

    nonisolated func setConfigurationOption(
        sessionID: String,
        configID: String,
        value: MCPJSONValue
    ) async throws -> [ACPConfigOption] {
        try await runtime.setConfigurationOption(
            sessionID: sessionID,
            configID: configID,
            value: value
        )
    }

    private actor State {
        private var sessions: [String: String] = [:]

        func insert(sessionID: String, cwd: String) {
            sessions[sessionID] = cwd
        }

        func cwd(for sessionID: String) -> String? {
            sessions[sessionID]
        }
    }
}

nonisolated enum ACPApplicationRuntimeError: LocalizedError, Equatable, Sendable {
    case sessionNotFound(String)
    case invalidPrompt(String)
    case invalidConfiguration(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let sessionID):
            "ACP session '\(sessionID)' does not exist."
        case .invalidPrompt(let message),
             .invalidConfiguration(let message),
             .executionFailed(let message):
            message
        }
    }
}
