import Foundation

/// Reasoning levels exposed by Codex App Server. They intentionally remain
/// separate from FoundationModels' three-level abstraction so TurboCode does
/// not discard Luna's `xhigh` and `max` options.
nonisolated enum CodexReasoningEffort: String, CaseIterable, Codable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    var displayName: String {
        switch self {
        case .low: "Light"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }
}

nonisolated struct CodexReasoningOption: Codable, Sendable, Hashable {
    let reasoningEffort: CodexReasoningEffort
    let description: String
}

nonisolated struct CodexModelDescriptor: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let supportedReasoningEfforts: [CodexReasoningOption]
    let defaultReasoningEffort: CodexReasoningEffort
}

nonisolated struct CodexRuntimeSnapshot: Sendable, Hashable {
    let accountEmail: String?
    let planType: String?
    let models: [CodexModelDescriptor]
    let selectedModel: CodexModelDescriptor
}

nonisolated enum CodexConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case signedOut
    case authenticating
    case ready(planType: String?)
    case failed(String)
}

nonisolated struct CodexLoginSession: Sendable, Equatable {
    let id: String
    let authorizationURL: URL
}

nonisolated enum CodexTurnEvent: Sendable, Equatable {
    case agentDelta(String)
    case reasoningDelta(String)
    case diffUpdated(String)
    case toolCallRequested(CodexDynamicToolCall)
    case approvalRequested(CodexApprovalRequest)
    case tokenUsageUpdated(CodexTokenUsage)
    case completed(status: String, errorMessage: String?)
}

/// App Server reports both the latest turn's context consumption and a
/// cumulative total. Handoff compaction uses `lastTotalTokens`: cumulative
/// usage counts repeated context across turns and is not the current size.
nonisolated struct CodexTokenUsage: Sendable, Equatable {
    let lastTotalTokens: Int
    let cumulativeTotalTokens: Int
    let modelContextWindow: Int?
}

/// A server-initiated approval request. The protocol-specific response bodies
/// stay attached to the request so ChatStore only decides Allow or Deny and
/// never needs to reconstruct Codex JSON-RPC details.
nonisolated struct CodexApprovalRequest: Sendable, Equatable {
    let rpcID: CodexRPCID
    let operation: String
    let path: String
    let summary: String
    let acceptedResult: CodexJSONValue
    let declinedResult: CodexJSONValue

    var presentationID: String {
        "codex-\(rpcID.stringValue)"
    }
}

nonisolated enum CodexAppServerError: LocalizedError, Sendable {
    case executableNotFound
    case serverStopped
    case invalidResponse(String)
    case turnFailed(String)
    case rpc(code: Int, message: String)
    case requestTimedOut(method: String, serverDetail: String?)
    case chatGPTLoginRequired
    case loginFailed(String)
    case modelUnavailable
    case turnAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex CLI was not found. Install Codex before selecting this profile."
        case .serverStopped:
            "Codex App Server stopped unexpectedly."
        case .invalidResponse(let detail):
            "Codex App Server returned an invalid response: \(detail)"
        case .turnFailed(let detail):
            "Codex turn failed: \(detail)"
        case .rpc(_, let message):
            message
        case .requestTimedOut(let method, let serverDetail):
            if let serverDetail {
                "Codex App Server did not answer \(method) within 20 seconds. "
                    + "Last runtime message: \(serverDetail)"
            } else {
                "Codex App Server did not answer \(method) within 20 seconds."
            }
        case .chatGPTLoginRequired:
            "Sign in with ChatGPT through Codex before selecting this profile."
        case .loginFailed(let detail):
            "Codex sign-in failed: \(detail)"
        case .modelUnavailable:
            "No Codex model is available for the current ChatGPT account."
        case .turnAlreadyRunning:
            "A Codex turn is already running."
        }
    }

    var requiresChatGPTLogin: Bool {
        switch self {
        case .chatGPTLoginRequired:
            return true
        case .rpc(_, let message),
                .invalidResponse(let message),
                .turnFailed(let message):
            let normalized = message.lowercased()
            return normalized.contains("not logged in")
                || normalized.contains("sign in")
                || normalized.contains("authentication required")
                || normalized.contains("unauthorized")
        default:
            return false
        }
    }
}

/// Owns one local `codex app-server` process and its JSON-RPC transport.
///
/// Keeping transport details behind an actor prevents stdout notifications,
/// request continuations and process lifetime from crossing isolation domains.
/// TurboCode never reads or copies Codex credentials; authentication remains
/// owned by the official Codex runtime.
actor CodexAppServerClient {
    static let lunaModelID = "gpt-5.6-luna"
    /// `thread/start` uses the kebab-case wire value, even though App Server
    /// reports the resolved sandbox back as the camel-case `workspaceWrite`.
    static let workspaceSandbox = "workspace-write"

    private var process: Process?
    private var inputHandle: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var errorOutputBuffer = Data()
    private var connectionTask: Task<Void, any Error>?
    private var isInitialized = false
    private var nextRequestID = 1
    private var pendingRequests: [
        Int: CheckedContinuation<CodexJSONValue, any Error>
    ] = [:]
    private var requestTimeoutTasks: [Int: Task<Void, Never>] = [:]
    private var activeTurnContinuation:
        AsyncThrowingStream<CodexTurnEvent, any Error>.Continuation?
    private var activeThreadID: String?
    private var activeTurnID: String?
    private var activeLoginIDs: Set<String> = []
    private var lastStandardErrorLine: String?
    private var completedLogins: [String: CodexLoginCompletion] = [:]
    private var loginContinuations: [
        String: CheckedContinuation<Void, any Error>
    ] = [:]

    /// Loads the account-scoped visible catalog and resolves a preferred model.
    /// App Server ordering is preserved because it reflects the runtime's own
    /// availability and recommendation policy.
    func prepareCodex(
        selectedModelID: String?
    ) async throws -> CodexRuntimeSnapshot {
        try await connectIfNeeded()

        // Account inspection is deliberately not a profile-selection gate.
        // On some macOS Keychain configurations `account/read` remains pending
        // even though authenticated Codex turns work. The first real thread
        // provides the authoritative auth result and routes failures to the
        // visible Sign In flow.
        let modelResult = try await request(
            method: "model/list",
            params: [
                "limit": .integer(50),
                "includeHidden": .bool(false)
            ]
        )
        let catalog: CodexModelListResult = try decode(modelResult)
        guard let selectedModel = Self.selectModel(
            from: catalog.data,
            preferredID: selectedModelID
        ) else {
            throw CodexAppServerError.modelUnavailable
        }

        return CodexRuntimeSnapshot(
            accountEmail: nil,
            planType: nil,
            models: catalog.data,
            selectedModel: selectedModel
        )
    }

    /// A saved account-specific choice wins; Luna remains the compatibility
    /// default, and the server's first visible model is the final fallback.
    nonisolated static func selectModel(
        from models: [CodexModelDescriptor],
        preferredID: String?
    ) -> CodexModelDescriptor? {
        preferredID.flatMap { requestedID in
            models.first(where: {
                $0.id == requestedID || $0.model == requestedID
            })
        } ?? models.first(where: {
            $0.id == Self.lunaModelID || $0.model == Self.lunaModelID
        }) ?? models.first
    }

    /// Starts the App Server managed ChatGPT OAuth flow. TurboCode opens the
    /// returned URL in the user's default browser and never handles tokens.
    func startChatGPTLogin() async throws -> CodexLoginSession {
        try await connectIfNeeded()
        let result = try await request(
            method: "account/login/start",
            params: [
                "type": .string("chatgpt"),
                "codexStreamlinedLogin": .bool(true),
                "useHostedLoginSuccessPage": .bool(true)
            ]
        )
        guard result["type"]?.stringValue == "chatgpt",
              let loginID = result["loginId"]?.stringValue,
              let rawURL = result["authUrl"]?.stringValue,
              let authorizationURL = URL(string: rawURL) else {
            throw CodexAppServerError.invalidResponse(
                "missing ChatGPT authorization URL"
            )
        }
        activeLoginIDs.insert(loginID)
        return CodexLoginSession(
            id: loginID,
            authorizationURL: authorizationURL
        )
    }

    /// Waits for the browser flow to report completion over App Server. A
    /// cached result closes the small race where OAuth finishes immediately.
    func waitForChatGPTLogin(id: String) async throws {
        if let completion = completedLogins.removeValue(forKey: id) {
            try completion.get()
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            loginContinuations[id] = continuation
        }
    }

    func startThread(
        workspaceRoot: String,
        modelID: String,
        dynamicTools: [CodexDynamicToolSpec],
        developerInstructions: String
    ) async throws -> String {
        try await connectIfNeeded()
        var params: [String: CodexJSONValue] = [
            "model": .string(modelID),
            // Codex keeps its own agent loop, while the workspace-write sandbox
            // limits mutations to the project selected in TurboCode.
            "sandbox": .string(Self.workspaceSandbox),
            // Escalations are routed into TurboCode's native Allow/Deny banner;
            // they must never be silently accepted by the App Server client.
            "approvalPolicy": .string("on-request"),
            "serviceName": .string("turbocode"),
            // Dynamic tools are sticky thread configuration. Codex selects
            // them inside its native loop while TurboCode executes them.
            "dynamicTools": .array(dynamicTools.map(\.jsonValue)),
            "developerInstructions": .string(developerInstructions)
        ]
        if !workspaceRoot.isEmpty {
            params["cwd"] = .string(workspaceRoot)
        }

        let result = try await request(method: "thread/start", params: params)
        guard let threadID = result["thread"]?["id"]?.stringValue else {
            throw CodexAppServerError.invalidResponse("missing thread id")
        }
        return threadID
    }

    func startTurn(
        threadID: String,
        text: String,
        workspaceRoot: String,
        modelID: String,
        effort: CodexReasoningEffort,
        additionalApplicationContext: String? = nil
    ) async throws -> AsyncThrowingStream<CodexTurnEvent, any Error> {
        guard activeTurnContinuation == nil else {
            throw CodexAppServerError.turnAlreadyRunning
        }

        var continuation:
            AsyncThrowingStream<CodexTurnEvent, any Error>.Continuation?
        let stream = AsyncThrowingStream<CodexTurnEvent, any Error> {
            continuation = $0
        }
        guard let continuation else {
            throw CodexAppServerError.invalidResponse("could not create event stream")
        }
        activeTurnContinuation = continuation
        activeThreadID = threadID

        var params: [String: CodexJSONValue] = [
            "threadId": .string(threadID),
            "input": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ]),
            "model": .string(modelID),
            "effort": .string(effort.rawValue),
            "summary": .string("concise")
        ]
        if !workspaceRoot.isEmpty {
            params["cwd"] = .string(workspaceRoot)
        }
        if let additionalApplicationContext,
           !additionalApplicationContext.isEmpty {
            // Application context initializes a Codex turn without fabricating
            // a user-authored message in the conversation.
            params["additionalContext"] = .object([
                "turbocode_session_handoff": .object([
                    "kind": .string("application"),
                    "value": .string(additionalApplicationContext)
                ])
            ])
        }

        do {
            let result = try await request(method: "turn/start", params: params)
            guard let turnID = result["turn"]?["id"]?.stringValue else {
                throw CodexAppServerError.invalidResponse("missing turn id")
            }
            activeTurnID = turnID
            return stream
        } catch {
            finishActiveTurn(throwing: error)
            throw error
        }
    }

    func interruptActiveTurn() async {
        guard let activeThreadID, let activeTurnID else { return }
        _ = try? await request(
            method: "turn/interrupt",
            params: [
                "threadId": .string(activeThreadID),
                "turnId": .string(activeTurnID)
            ]
        )
    }

    /// Completes the exact JSON-RPC request that produced the visible approval
    /// banner. Responses are intentionally one-shot and scoped to this turn.
    func resolveApproval(
        _ request: CodexApprovalRequest,
        approved: Bool
    ) throws {
        try send(
            .object([
                "id": request.rpcID.jsonValue,
                "result": approved
                    ? request.acceptedResult
                    : request.declinedResult
            ])
        )
    }

    /// Returns client-side dynamic tool output to the exact App Server request
    /// that paused the Codex loop. Failures are model-visible and still close
    /// the request, preventing a malformed tool call from hanging the turn.
    func resolveToolCall(
        _ call: CodexDynamicToolCall,
        result: CodexDynamicToolResult
    ) throws {
        try send(
            .object([
                "id": call.rpcID.jsonValue,
                "result": .object([
                    "contentItems": .array([
                        .object([
                            "type": .string("inputText"),
                            "text": .string(result.text)
                        ])
                    ]),
                    "success": .bool(result.succeeded)
                ])
            ])
        )
    }

    /// Explicit shutdown is used by integration tests and future app lifecycle
    /// handling so a helper process is never left detached from TurboCode.
    func shutdown() {
        readerTask?.cancel()
        errorReaderTask?.cancel()
        try? inputHandle?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        serverDidStop()
    }

    private func connectIfNeeded() async throws {
        if process?.isRunning == true, isInitialized { return }
        if let connectionTask {
            try await connectionTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { throw CodexAppServerError.serverStopped }
            try await self.launchAndInitialize()
        }
        connectionTask = task
        do {
            try await task.value
            isInitialized = true
            connectionTask = nil
        } catch {
            connectionTask = nil
            throw error
        }
    }

    private func launchAndInitialize() async throws {
        let executable = try Self.codexExecutableURL()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        self.process = process
        inputHandle = inputPipe.fileHandleForWriting

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading

        // Blocking FileHandle reads run outside the actor. `availableData`
        // returns as soon as the pipe has bytes; `read(upToCount:)` can wait
        // for its full requested size and hold a short JSON-RPC response until
        // EOF. receiveOutput then performs JSONL framing in one place.
        readerTask = Task.detached { [weak self, outputHandle] in
            while !Task.isCancelled {
                let data = outputHandle.availableData
                guard !data.isEmpty else {
                    await self?.serverDidStop()
                    return
                }
                await self?.receiveOutput(data)
            }
        }
        errorReaderTask = Task.detached { [weak self, errorHandle] in
            while !Task.isCancelled {
                let data = errorHandle.availableData
                guard !data.isEmpty else {
                    return
                }
                await self?.receiveErrorOutput(data)
            }
        }

        do {
            _ = try await request(
                method: "initialize",
                params: [
                    "clientInfo": .object([
                        "name": .string("turbocode"),
                        "title": .string("TurboCode"),
                        "version": .string(
                            Bundle.main.object(
                                forInfoDictionaryKey: "CFBundleShortVersionString"
                            ) as? String ?? "0.1.0"
                        )
                    ]),
                    // App Server currently gates client-provided dynamic tools
                    // behind this capability; opting in is explicit and local
                    // to the TurboCode connection.
                    "capabilities": .object([
                        "experimentalApi": .bool(true)
                    ])
                ]
            )
            try sendNotification(method: "initialized", params: [:])
        } catch {
            process.terminate()
            serverDidStop(error: error)
            throw error
        }
    }

    private func request(
        method: String,
        params: [String: CodexJSONValue],
        timeout: Duration = .seconds(20)
    ) async throws -> CodexJSONValue {
        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
            // A child process can be alive while blocked on Keychain or a
            // malformed request. Every RPC therefore has a bounded lifetime,
            // so the UI always reaches either ready or an actionable error.
            requestTimeoutTasks[id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self?.requestDidTimeOut(id: id, method: method)
            }
            do {
                try send(
                    .object([
                        "method": .string(method),
                        "id": .integer(id),
                        "params": .object(params)
                    ])
                )
            } catch {
                requestTimeoutTasks.removeValue(forKey: id)?.cancel()
                pendingRequests.removeValue(forKey: id)?
                    .resume(throwing: error)
            }
        }
    }

    private func requestDidTimeOut(id: Int, method: String) {
        requestTimeoutTasks.removeValue(forKey: id)
        pendingRequests.removeValue(forKey: id)?.resume(
            throwing: CodexAppServerError.requestTimedOut(
                method: method,
                serverDetail: lastStandardErrorLine
            )
        )
    }

    private func recordStandardError(_ line: String) {
        // Keep only the latest bounded diagnostic. App Server writes useful
        // startup and credential failures to stderr, but TurboCode must not
        // accumulate an unbounded log or mirror conversation contents.
        lastStandardErrorLine = String(line.suffix(500))
    }

    private func sendNotification(
        method: String,
        params: [String: CodexJSONValue]
    ) throws {
        try send(
            .object([
                "method": .string(method),
                "params": .object(params)
            ])
        )
    }

    private func send(_ value: CodexJSONValue) throws {
        guard let inputHandle else {
            throw CodexAppServerError.serverStopped
        }
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receiveOutput(_ data: Data) {
        for line in Self.framedLines(from: data, buffer: &outputBuffer) {
            receive(line)
        }
    }

    private func receiveErrorOutput(_ data: Data) {
        for line in Self.framedLines(from: data, buffer: &errorOutputBuffer) {
            recordStandardError(line)
        }
    }

    /// Frames arbitrary pipe chunks into complete UTF-8 JSONL records while
    /// retaining a partial trailing record for the next read.
    nonisolated static func framedLines(
        from data: Data,
        buffer: inout Data
    ) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            // Copy the framed line before mutating its backing buffer. A Data
            // slice may share storage with buffer and becomes invalid as soon
            // as removeSubrange consumes the corresponding bytes.
            var lineData = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if lineData.last == 0x0D {
                lineData.removeLast()
            }
            if !lineData.isEmpty,
               let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    private func receive(_ line: String) {
        guard let data = line.data(using: .utf8) else {
            failPendingRequestsForInvalidMessage(
                "stdout contained text that was not valid UTF-8"
            )
            return
        }

        let message: CodexRPCMessage
        do {
            message = try JSONDecoder().decode(
                CodexRPCMessage.self,
                from: data
            )
        } catch {
            // A malformed response used to be discarded silently, leaving the
            // matching request alive until its 20-second timeout. Surface the
            // decoder failure immediately without echoing response contents,
            // which may contain the user's workspace or conversation data.
            failPendingRequestsForInvalidMessage(
                "could not decode a JSON-RPC message (\(error))"
            )
            return
        }

        if let id = message.id, let method = message.method {
            if method == "item/tool/call",
               let params = message.params,
               let call = Self.dynamicToolCall(id: id, params: params) {
                activeTurnContinuation?.yield(.toolCallRequested(call))
                return
            }
            guard let params = message.params,
                  let approval = Self.approvalRequest(
                      id: id,
                      method: method,
                      params: params
                  ) else {
                // Unknown server requests must receive a response; ignoring
                // them would leave the Codex turn blocked indefinitely.
                try? send(
                    .object([
                        "id": id.jsonValue,
                        "error": .object([
                            "code": .integer(-32601),
                            "message": .string(
                                "TurboCode does not support \(method)."
                            )
                        ])
                    ])
                )
                return
            }
            activeTurnContinuation?.yield(.approvalRequested(approval))
            return
        }

        if let id = message.id {
            guard case .integer(let requestID) = id,
                  let continuation = pendingRequests.removeValue(
                      forKey: requestID
                  ) else { return }
            requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            if let error = message.error {
                continuation.resume(
                    throwing: CodexAppServerError.rpc(
                        code: error.code,
                        message: error.message
                    )
                )
            } else {
                continuation.resume(returning: message.result ?? .null)
            }
            return
        }

        guard let method = message.method,
              let params = message.params else { return }
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"]?.stringValue {
                activeTurnContinuation?.yield(.agentDelta(delta))
            }
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            if let delta = params["delta"]?.stringValue {
                activeTurnContinuation?.yield(.reasoningDelta(delta))
            }
        case "turn/diff/updated":
            if let diff = params["diff"]?.stringValue {
                activeTurnContinuation?.yield(.diffUpdated(diff))
            }
        case "thread/tokenUsage/updated":
            if let usage = Self.tokenUsage(from: params) {
                activeTurnContinuation?.yield(.tokenUsageUpdated(usage))
            }
        case "turn/completed":
            let turn = params["turn"]
            let status = turn?["status"]?.stringValue ?? "completed"
            let errorMessage = turn?["error"]?["message"]?.stringValue
            activeTurnContinuation?.yield(
                .completed(status: status, errorMessage: errorMessage)
            )
            finishActiveTurn()
        case "account/login/completed":
            completeLogin(
                id: params["loginId"]?.stringValue,
                succeeded: params["success"]?.boolValue ?? false,
                errorMessage: params["error"]?.stringValue
            )
        case "error":
            let message = params["error"]?["message"]?.stringValue
                ?? params["message"]?.stringValue
                ?? "Codex turn failed."
            // This notification reports a valid protocol message describing a
            // runtime/model failure (for example temporary model capacity).
            // Keep malformed JSON-RPC reserved for `invalidResponse` so the UI
            // does not misdiagnose an operational failure as a bridge defect.
            finishActiveTurn(
                throwing: CodexAppServerError.turnFailed(message)
            )
        default:
            break
        }
    }

    /// Decodes only the documented dynamic-tool request shape. Keeping the raw
    /// arguments as a Sendable JSON tree lets the concrete TurboCode bridge
    /// validate each schema without leaking `[String: Any]` across actors.
    nonisolated static func dynamicToolCall(
        id: CodexRPCID,
        params: CodexJSONValue
    ) -> CodexDynamicToolCall? {
        guard let callID = params["callId"]?.stringValue,
              let tool = params["tool"]?.stringValue,
              let arguments = params["arguments"] else {
            return nil
        }
        return CodexDynamicToolCall(
            rpcID: id,
            callID: callID,
            tool: tool,
            arguments: arguments
        )
    }

    nonisolated static func tokenUsage(
        from params: CodexJSONValue
    ) -> CodexTokenUsage? {
        guard let usage = params["tokenUsage"],
              let last = usage["last"]?["totalTokens"]?.integerValue,
              let cumulative = usage["total"]?["totalTokens"]?.integerValue else {
            return nil
        }
        return CodexTokenUsage(
            lastTotalTokens: last,
            cumulativeTotalTokens: cumulative,
            modelContextWindow: usage["modelContextWindow"]?.integerValue
        )
    }

    private func failPendingRequestsForInvalidMessage(_ detail: String) {
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for task in requestTimeoutTasks.values {
            task.cancel()
        }
        requestTimeoutTasks.removeAll()
        let failure = CodexAppServerError.invalidResponse(detail)
        for continuation in continuations {
            continuation.resume(throwing: failure)
        }
    }

    private func completeLogin(
        id: String?,
        succeeded: Bool,
        errorMessage: String?
    ) {
        // Current App Server versions may omit loginId in the completion
        // notification. TurboCode allows one interactive login at a time, so
        // the sole active identifier is unambiguous in that case.
        let resolvedID = id ?? (activeLoginIDs.count == 1
            ? activeLoginIDs.first
            : nil)
        guard let resolvedID else { return }
        activeLoginIDs.remove(resolvedID)
        let completion: CodexLoginCompletion = succeeded
            ? .success
            : .failure(errorMessage ?? "The browser authorization was not completed.")
        if let continuation = loginContinuations.removeValue(
            forKey: resolvedID
        ) {
            do {
                try completion.get()
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        } else {
            completedLogins[resolvedID] = completion
        }
    }

    /// Converts only the approval requests TurboCode can review faithfully.
    /// Permission grants preserve the exact profile requested by Codex when
    /// allowed and return an empty profile when denied.
    nonisolated static func approvalRequest(
        id: CodexRPCID,
        method: String,
        params: CodexJSONValue
    ) -> CodexApprovalRequest? {
        let path = params["cwd"]?.stringValue
            ?? params["grantRoot"]?.stringValue
            ?? ""
        let reason = params["reason"]?.stringValue

        switch method {
        case "item/commandExecution/requestApproval":
            let command = params["command"]?.stringValue
                ?? "Run the requested command"
            return CodexApprovalRequest(
                rpcID: id,
                operation: "command",
                path: path,
                summary: reason.map { "\(command) — \($0)" } ?? command,
                acceptedResult: .object(["decision": .string("accept")]),
                declinedResult: .object(["decision": .string("decline")])
            )
        case "item/fileChange/requestApproval":
            return CodexApprovalRequest(
                rpcID: id,
                operation: "write",
                path: path,
                summary: reason ?? "Apply the proposed file changes",
                acceptedResult: .object(["decision": .string("accept")]),
                declinedResult: .object(["decision": .string("decline")])
            )
        case "item/permissions/requestApproval":
            let requestedPermissions = params["permissions"] ?? .object([:])
            return CodexApprovalRequest(
                rpcID: id,
                operation: "permissions",
                path: path,
                summary: reason ?? "Grant additional permissions for this turn",
                acceptedResult: .object([
                    "permissions": requestedPermissions,
                    "scope": .string("turn")
                ]),
                declinedResult: .object([
                    "permissions": .object([:]),
                    "scope": .string("turn")
                ])
            )
        default:
            return nil
        }
    }

    private func finishActiveTurn(throwing error: (any Error)? = nil) {
        if let error {
            activeTurnContinuation?.finish(throwing: error)
        } else {
            activeTurnContinuation?.finish()
        }
        activeTurnContinuation = nil
        activeThreadID = nil
        activeTurnID = nil
    }

    private func serverDidStop(error: (any Error)? = nil) {
        let failure = error ?? CodexAppServerError.serverStopped
        let continuations = pendingRequests.values
        pendingRequests.removeAll()
        for task in requestTimeoutTasks.values {
            task.cancel()
        }
        requestTimeoutTasks.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: failure)
        }
        let loginWaiters = loginContinuations.values
        loginContinuations.removeAll()
        for continuation in loginWaiters {
            continuation.resume(throwing: failure)
        }
        activeLoginIDs.removeAll()
        completedLogins.removeAll()
        finishActiveTurn(throwing: failure)
        inputHandle = nil
        process = nil
        readerTask = nil
        errorReaderTask = nil
        connectionTask = nil
        isInitialized = false
        lastStandardErrorLine = nil
        outputBuffer.removeAll(keepingCapacity: false)
        errorOutputBuffer.removeAll(keepingCapacity: false)
    }

    private func decode<T: Decodable>(_ value: CodexJSONValue) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// GUI apps do not always inherit Homebrew's PATH. Explicit candidates
    /// keep discovery deterministic without invoking a shell.
    private static func codexExecutableURL() throws -> URL {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = environmentPath
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") }
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ] + pathCandidates
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw CodexAppServerError.executableNotFound
        }
        return executable
    }

}

private nonisolated enum CodexLoginCompletion: Sendable {
    case success
    case failure(String)

    func get() throws {
        if case .failure(let detail) = self {
            throw CodexAppServerError.loginFailed(detail)
        }
    }
}

nonisolated struct CodexModelListResult: Codable {
    let data: [CodexModelDescriptor]
}

private nonisolated struct CodexRPCError: Codable {
    let code: Int
    let message: String
}

private nonisolated struct CodexRPCMessage: Codable {
    let id: CodexRPCID?
    let method: String?
    let result: CodexJSONValue?
    let error: CodexRPCError?
    let params: CodexJSONValue?
}

nonisolated enum CodexRPCID: Codable, Sendable, Equatable, Hashable {
    case integer(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .integer(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    var jsonValue: CodexJSONValue {
        switch self {
        case .integer(let value): .integer(value)
        case .string(let value): .string(value)
        }
    }

    var stringValue: String {
        switch self {
        case .integer(let value): String(value)
        case .string(let value): value
        }
    }
}

/// Minimal JSON value used at the protocol boundary. Using a Sendable value
/// tree avoids leaking `[String: Any]` across the App Server actor.
nonisolated enum CodexJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([CodexJSONValue])
    case object([String: CodexJSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CodexJSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    subscript(_ key: String) -> CodexJSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}
