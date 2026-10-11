import Foundation

/// Everything a Cowork session's tools need, and nothing more: the single VM
/// runtime, the configuration it must boot with, and the session identity.
///
/// Tools receive this value instead of any store, so they cannot reach the
/// Mac's workspace, approvals, or UI state. A session without this context
/// cannot be a Cowork session.
nonisolated struct CoworkSessionContext: Sendable {
    static let sessionsRoot = "/home/cowork/sessions"

    let runtime: any CoworkVMRuntime
    let configuration: CoworkVMConfiguration
    let sessionID: String

    /// The session's private working directory inside the guest. The ID is
    /// reduced to a safe path component because it becomes a guest path.
    var sessionDirectory: String {
        let safe = sessionID.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            .map(String.init)
            .joined()
        return "\(Self.sessionsRoot)/\(safe.isEmpty ? "default" : safe)"
    }

    /// Resolves a model-supplied guest path. Relative paths start at the
    /// session directory; absolute paths are allowed because the whole guest
    /// belongs to the agent and the host is protected by the VM boundary.
    func guestPath(_ path: String?) -> String {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != "." else { return sessionDirectory }
        if trimmed.hasPrefix("/") { return trimmed }
        if trimmed.hasPrefix("~/") { return "/home/cowork/" + trimmed.dropFirst(2) }
        return "\(sessionDirectory)/\(trimmed)"
    }

    /// Boots the VM when needed, ensures the session directory exists, and
    /// runs `script` from `workingDirectory` as the unprivileged agent user.
    func run(
        _ script: String,
        workingDirectory: String? = nil,
        timeout: Duration = .seconds(120),
        stdin: Data? = nil
    ) async throws -> CoworkExecResult {
        try await runtime.start(configuration)
        let directory = guestPath(workingDirectory)
        // The exec working directory must exist before the process starts, so
        // the wrapper creates the session directory and then changes into the
        // requested one; the model's script runs unchanged inside the group.
        let wrapped = """
            mkdir -p \(CoworkShell.quote(sessionDirectory)) && cd -- \(CoworkShell.quote(directory)) || exit 97
            {
            \(script)
            }
            """
        let started = ContinuousClock.now
        let stream = try await runtime.exec(CoworkExecRequest(
            script: wrapped,
            workingDirectory: "/",
            timeout: timeout,
            stdin: stdin
        ))
        var result = CoworkExecResult()
        for try await event in stream {
            switch event {
            case .stdout(let data): result.stdout.append(data)
            case .stderr(let data): result.stderr.append(data)
            case .exited(let code): result.exitCode = code
            case .timedOut: result.timedOut = true
            }
        }
        result.duration = ContinuousClock.now - started
        return result
    }
}

nonisolated struct CoworkExecResult: Sendable, Equatable {
    var exitCode: Int32?
    var timedOut = false
    var stdout = Data()
    var stderr = Data()
    var duration: Duration = .zero
}

nonisolated enum CoworkShell {
    /// POSIX single-quoting: safe for any byte sequence except NUL.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Renders guest output for the model. Local models have small context
/// windows, so long output keeps its beginning and its end (where errors and
/// summaries usually are) and states exactly how much was omitted.
nonisolated enum CoworkOutputFormatter {
    static let headCharacters = 3_000
    static let tailCharacters = 6_000

    static func render(_ result: CoworkExecResult) -> String {
        var lines: [String] = []
        let seconds = Double(result.duration.components.seconds)
            + Double(result.duration.components.attoseconds) / 1e18
        if result.timedOut {
            lines.append("Timed out after \(String(format: "%.1f", seconds)) s; the process was killed.")
        } else {
            lines.append("Exit code \(result.exitCode.map(String.init) ?? "unknown") in \(String(format: "%.1f", seconds)) s.")
        }
        let stdout = truncate(String(decoding: result.stdout, as: UTF8.self))
        let stderr = truncate(String(decoding: result.stderr, as: UTF8.self))
        if !stdout.isEmpty { lines.append("stdout:\n\(stdout)") }
        if !stderr.isEmpty { lines.append("stderr:\n\(stderr)") }
        if stdout.isEmpty, stderr.isEmpty { lines.append("(no output)") }
        return lines.joined(separator: "\n")
    }

    static func truncate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard trimmed.count > headCharacters + tailCharacters else { return trimmed }
        let head = trimmed.prefix(headCharacters)
        let tail = trimmed.suffix(tailCharacters)
        let omitted = trimmed.count - headCharacters - tailCharacters
        return "\(head)\n… \(omitted) characters omitted …\n\(tail)"
    }
}

/// The application-side port that turns a Cowork conversation into a session
/// context. `CoworkStore` implements it; chat coordinators depend only on this
/// protocol, never on Settings state.
@MainActor
protocol CoworkSessionProviding: AnyObject {
    /// `nil` when the conversation is not Cowork or Cowork is not ready.
    func sessionContext(for conversation: Conversation) -> CoworkSessionContext?
}

/// Why a Cowork turn cannot run. There is no fallback to Coding.
nonisolated enum CoworkAdmission: Equatable {
    case allowed
    case rejected(String)

    static let codexMessage = "Cowork sessions run in the Cowork VM and cannot use Codex, which executes on this Mac. Choose an on-device, Llama, or DeepSeek profile."
    static let unavailableMessage = "Cowork is not available. Enable and install it in Settings › Cowork."
    static let independentTaskMessage = "Independent tasks are not available in Cowork sessions yet."

    /// Pure admission rule shared by every entry point that starts a turn.
    static func evaluate(domain: SessionDomain, backend: ModelBackend, hasContext: Bool) -> Self {
        guard domain == .cowork else { return .allowed }
        if backend == .codex { return .rejected(codexMessage) }
        return hasContext ? .allowed : .rejected(unavailableMessage)
    }
}

nonisolated enum CoworkFolderError: LocalizedError {
    case agentIsWorking

    var errorDescription: String? {
        switch self {
        case .agentIsWorking: "Wait for the agent to finish before changing the shared folder."
        }
    }
}
