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
    let taskScope: AgentTaskPathScope?
    private let sdkRoot: String
    private let homeDirectory: String
    private let requestApproval: @Sendable (PendingToolApproval) async -> String
    private let sandboxViolationMonitor: any BashSandboxViolationMonitoring
    private let service: BashService

    init(
        workspaceRoot: String,
        executionPolicy: ExecutionPolicy = ExecutionPolicy(),
        taskScope: AgentTaskPathScope? = nil,
        sdkRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode/sdk", isDirectory: true).path,
        // Production uses the real home so `~` keeps its normal shell meaning.
        // Tests may inject a disposable home without changing runtime behavior.
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        sandboxViolationMonitor: any BashSandboxViolationMonitoring = BashSandboxViolationMonitor.shared,
        requestApproval: @escaping @Sendable (PendingToolApproval) async -> String = {
            await ToolApprovalRegistry.shared.request($0)
        }
    ) {
        self.workspaceRoot = workspaceRoot
        self.executionPolicy = executionPolicy
        self.taskScope = taskScope
        self.sdkRoot = sdkRoot
        self.homeDirectory = homeDirectory
        self.sandboxViolationMonitor = sandboxViolationMonitor
        self.service = BashService(monitor: sandboxViolationMonitor)
        self.requestApproval = requestApproval
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(
            workspaceRoot: workspaceRoot,
            executionPolicy: executionPolicy,
            taskScope: scope,
            sdkRoot: sdkRoot,
            homeDirectory: homeDirectory,
            sandboxViolationMonitor: sandboxViolationMonitor,
            requestApproval: requestApproval
        )
    }

    var name: String { "bash" }
    var description: String {
        """
        Run any zsh command from the workspace root. Check pwd before destructive
        relative commands.
        If the host sandbox blocks an external path, TurboCode asks the user and
        reruns this exact command after approval; never invent an approval token.
        Output and execution time are bounded.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: BashArguments) async throws -> String {
        let command = arguments.command
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
            allowNetworkAccess: executionPolicy.allowNetworkAccess,
            sdkRoot: sdkRoot,
            homeDirectory: homeDirectory,
            requestApproval: requestApproval
        )
    }
}

// MARK: - Sandboxed Process Runner

private actor BashService {
    private let monitor: any BashSandboxViolationMonitoring

    init(monitor: any BashSandboxViolationMonitoring) {
        self.monitor = monitor
    }

    func run(
        command: String,
        workspaceRoot: String,
        timeoutSeconds: Int,
        outputLimit: Int,
        allowNetworkAccess: Bool,
        sdkRoot: String,
        homeDirectory: String,
        requestApproval: @Sendable (PendingToolApproval) async -> String
    ) async -> String {
        guard !Task.isCancelled else { return BashOutcome.cancelled.wrap("Command cancelled before execution.") }
        let firstMonitor: BashSandboxMonitorInvocation
        switch await monitor.begin() {
        case .unavailable(let reason):
            return (Task.isCancelled ? BashOutcome.cancelled : .diagnosticsIncomplete)
                .wrap("Error: sandbox diagnostics unavailable: \(reason) Command was not run.")
        case .ready(let invocation):
            firstMonitor = invocation
        }
        let first = await execute(
            command: command, workspaceRoot: workspaceRoot, timeoutSeconds: timeoutSeconds,
            outputLimit: outputLimit, allowNetworkAccess: allowNetworkAccess,
            sdkRoot: sdkRoot, homeDirectory: homeDirectory,
            allowExternalAccess: false, sandboxMessage: firstMonitor.tag
        )
        let observation = await monitor.end(firstMonitor)
        let firstText = first.render(observation: observation, outputLimit: outputLimit)
        // Process state is kept separate from printable output. A denial never
        // revives a timed-out/cancelled attempt or one with uncertain cleanup.
        guard first.process.canRerun, !Task.isCancelled else {
            return (Task.isCancelled ? BashOutcome.cancelled : first.outcome(observation))
                .wrap(firstText + "\n\nThe complete command was not rerun.")
        }
        guard !observation.violations.isEmpty else {
            return first.outcome(observation).wrap(firstText)
        }
        let authorized = await WorkspaceAccessGate.shared.authorizeExternalExecution(
            tool: "Bash", workspaceRoot: workspaceRoot,
            targetDescription: observation.violations.map(\.path).joined(separator: "\n"),
            command: command, requestApproval: requestApproval
        )
        guard !Task.isCancelled else {
            return BashOutcome.cancelled.wrap(firstText + "\n\nCommand cancelled. The complete command was not rerun.")
        }
        guard authorized else {
            return BashOutcome.pathDenied.wrap(firstText + "\n\nExternal filesystem access denied by the user. The complete command was not rerun.")
        }
        let retryMonitor: BashSandboxMonitorInvocation
        switch await monitor.begin() {
        case .unavailable(let reason):
            return (Task.isCancelled ? BashOutcome.cancelled : .diagnosticsIncomplete).wrap(
                firstText + "\n\nApproved, but the complete command was not rerun because sandbox diagnostics became unavailable: \(reason)"
            )
        case .ready(let invocation):
            retryMonitor = invocation
        }
        // execute checks cancellation again after begin's suspension and just
        // before spawning. end always closes the monitor, including on Stop.
        let retry = await execute(
            command: command, workspaceRoot: workspaceRoot, timeoutSeconds: timeoutSeconds,
            outputLimit: outputLimit, allowNetworkAccess: allowNetworkAccess,
            sdkRoot: sdkRoot, homeDirectory: homeDirectory,
            allowExternalAccess: true, sandboxMessage: retryMonitor.tag
        )
        let retryObservation = await monitor.end(retryMonitor)
        // Only the final attempt decides the host outcome. Share the original
        // output budget between attempts, retaining both sets of metadata.
        let text = "First attempt:\n" + first.render(observation: observation, outputLimit: outputLimit / 2)
            + "\n\nApproved complete rerun:\n" + retry.render(observation: retryObservation, outputLimit: outputLimit / 2)
        return (Task.isCancelled ? BashOutcome.cancelled : retry.outcome(retryObservation)).wrap(text)
    }

    private func execute(
        command: String,
        workspaceRoot: String,
        timeoutSeconds: Int,
        outputLimit: Int,
        allowNetworkAccess: Bool,
        sdkRoot: String,
        homeDirectory: String,
        allowExternalAccess: Bool,
        sandboxMessage: String
    ) async -> BashAttemptResult {
        let resolvedWorkspace = try? WorkspacePathResolver.resolve(".", within: workspaceRoot)
        let activeWorkspaceURL = resolvedWorkspace.flatMap { Self.isDirectory($0) ? $0 : nil }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Bash-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = outputDirectory.appendingPathComponent("stderr.txt")
        let shellHome = URL(fileURLWithPath: homeDirectory, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        } catch {
            return .failure("Error preparing command output: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        // A stale workspace must never redirect relative commands into a real
        // user directory. The temporary directory is intentionally disposable;
        // external roots remain reachable only after host authorization.
        let workingDirectoryURL = activeWorkspaceURL ?? outputDirectory

        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        do {
            stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            stderrHandle = try FileHandle(forWritingTo: stderrURL)
        } catch {
            return .failure("Error opening command output: \(error.localizedDescription)")
        }

        // GUI-launched apps often miss the shell's Node manager PATH. Reuse the
        // plugin resolver so npm, npx, and node scripts see the same supported
        // Node installation that TurboCode would use to launch a plugin.
        let nodeExecutable = try? NodeRuntimeResolver.resolve()
        let nodeBinDirectory = nodeExecutable?.deletingLastPathComponent().path
        let nodeRuntimeRoot = nodeExecutable?.deletingLastPathComponent()
            .deletingLastPathComponent().path
        let sdkPackage = URL(fileURLWithPath: sdkRoot)
            .appendingPathComponent("@granvalenti/turbocode-sdk", isDirectory: true)
            .path
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let commandPath = [nodeBinDirectory, inheritedPath]
            .compactMap { $0 }
            .joined(separator: ":")
        let arguments = [
            "-p",
            sandboxProfile(
                workspacePath: workingDirectoryURL.path,
                outputPath: outputDirectory.path,
                allowNetworkAccess: allowNetworkAccess,
                nodeRuntimeRoot: nodeRuntimeRoot,
                allowExternalAccess: allowExternalAccess,
                sandboxMessage: sandboxMessage
            ),
            "/bin/zsh",
            "-fc",
            command
        ]
        var commandEnvironment = ProcessInfo.processInfo.environment.merging([
            "TMPDIR": outputDirectory.path,
            "HOME": shellHome.path,
            "XDG_CACHE_HOME": outputDirectory.appendingPathComponent("cache").path,
            "TURBOCODE_SDK_PACKAGE": sdkPackage,
            "PATH": commandPath
        ]) { _, new in new }
        // Let zsh derive PWD from currentDirectoryURL. The SDK package is the
        // only public TurboCode locator; strip legacy variables even when the
        // app inherited them from its launcher.
        commandEnvironment.removeValue(forKey: "PWD")
        commandEnvironment.removeValue(forKey: "TURBOCODE_SDK_ROOT")
        commandEnvironment.removeValue(forKey: "TURBOCODE_PLUGIN_ROOT")
        commandEnvironment.removeValue(forKey: "TURBOCODE_NODE_PATH")
        let startedAt = ContinuousClock.now
        let process = await BashProcessRunner.run(
            executable: "/usr/bin/sandbox-exec", arguments: arguments,
            environment: commandEnvironment, directory: workingDirectoryURL.path,
            stdout: stdoutHandle.fileDescriptor, stderr: stderrHandle.fileDescriptor,
            timeout: .seconds(timeoutSeconds)
        )
        try? stdoutHandle.close()
        try? stderrHandle.close()
        let stdout = readOutput(at: stdoutURL, limit: outputLimit / 2)
        let stderr = readOutput(at: stderrURL, limit: outputLimit / 2)
        let duration = startedAt.duration(to: .now)
        var metadata = [
            "Working directory: \(workingDirectoryURL.path)",
            activeWorkspaceURL == nil
                ? "Workspace unavailable: relative paths use a disposable directory."
                : "Workspace: \(activeWorkspaceURL!.path)",
            "Exit code: \(process.exitCode.map(String.init) ?? "unavailable")",
            "Duration: \(duration)"
        ]
        if process.timedOut { metadata.append("Timed out after \(timeoutSeconds)s.") }
        if process.cancelled { metadata.append("Command cancelled.") }
        if !process.cleanupComplete {
            metadata.append("Command process cleanup could not be confirmed; no rerun is allowed.")
        }
        if let error = process.error { metadata.append(error) }
        return BashAttemptResult(
            process: process, metadata: metadata.joined(separator: "\n\n"),
            stdout: stdout.text, stderr: stderr.text,
            stdoutTruncated: stdout.truncated, stderrTruncated: stderr.truncated
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private func sandboxProfile(
        workspacePath: String,
        outputPath: String,
        allowNetworkAccess: Bool,
        nodeRuntimeRoot: String?,
        allowExternalAccess: Bool,
        sandboxMessage: String
    ) -> String {
        let workspace = profileEscaped(workspacePath)
        let output = profileEscaped(outputPath)
        var readableRootPaths = [workspacePath]
        if let nodeRuntimeRoot {
            readableRootPaths.append(nodeRuntimeRoot)
        }
        let readableRoots = readableRootPaths
            .map(readExceptionsProfile(for:))
            .joined(separator: " ")
        let networkPolicy = allowNetworkAccess ? "" : "(deny network*)"
        let filePolicy = allowExternalAccess
            ? ""
            : """
            (deny file-read*
                (require-any
                    (subpath "/Volumes")
                    (subpath "/Network")
                    (require-all
                        (subpath "/Users")
                        (require-not (require-any \(readableRoots))))
                    (require-all
                        (subpath "/private/tmp")
                        (require-not
                            (require-any
                                (literal "\(output)")
                                (subpath "\(output)")))))
                (with message "\(sandboxMessage)"))
            (deny file-write* (with message "\(sandboxMessage)"))
            (allow file-write* (subpath "\(output)"))
            (allow file-write* (subpath "/var/folders"))
            (allow file-write* (subpath "/private/var/folders"))
            (allow file-write* (literal "\(workspace)"))
            (allow file-write* (subpath "\(workspace)"))
            (allow file-write* (literal "\(workspace)/.build"))
            (allow file-write* (subpath "\(workspace)/.build"))
            (allow file-write* (literal "\(workspace)/.swiftpm"))
            (allow file-write* (subpath "\(workspace)/.swiftpm"))
            """
        return """
        (version 1)
        (allow default)
        \(networkPolicy)
        \(filePolicy)
        (allow file-write-data (literal "/dev/null"))
        """
    }

    private func readExceptionsProfile(for workspacePath: String) -> String {
        let components = NSString(string: workspacePath).pathComponents
        var currentPath = ""
        var literals: [String] = []

        for component in components {
            currentPath = currentPath.isEmpty
                ? component
                : NSString(string: currentPath).appendingPathComponent(component)
            guard currentPath == "/Users" || currentPath.hasPrefix("/Users/") else { continue }
            literals.append("(literal \"\(profileEscaped(currentPath))\")")
        }

        literals.append("(subpath \"\(profileEscaped(workspacePath))\")")
        return "(require-any \(literals.joined(separator: " ")))"
    }

    private func profileEscaped(_ value: String) -> String {
        var normalized = value
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
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

/// The first line is host-authored and precedes all untrusted command output.
/// Consumers can classify the final attempt without scanning earlier stdout or
/// a previous exit code. Keep the legacy classifier for stored older results.
nonisolated enum BashOutcome: String {
    case succeeded, failed, cancelled, timedOut, pathDenied, diagnosticsIncomplete

    func wrap(_ text: String) -> String { "Bash outcome: \(rawValue)\n\n\(text)" }

    static func read(from text: String) -> Self? {
        let prefix = "Bash outcome: "
        guard text.hasPrefix(prefix) else { return nil }
        return Self(rawValue: String(text.dropFirst(prefix.count).prefix { $0 != "\n" }))
    }
}

nonisolated private struct BashAttemptResult: Sendable {
    let process: BashProcessRunner.Result
    let metadata: String
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool

    static func failure(_ message: String) -> Self {
        Self(process: .init(exitCode: nil, timedOut: false, cancelled: false, cleanupComplete: true, error: message),
             metadata: message, stdout: "", stderr: "", stdoutTruncated: false, stderrTruncated: false)
    }

    func outcome(_ observation: BashSandboxMonitorObservation) -> BashOutcome {
        if process.cancelled { return .cancelled }
        if process.timedOut { return .timedOut }
        if !process.canRerun { return .failed }
        if !observation.violations.isEmpty { return .pathDenied }
        if !observation.isComplete { return .diagnosticsIncomplete }
        return process.exitCode == 0 ? .succeeded : .failed
    }

    func render(observation: BashSandboxMonitorObservation, outputLimit: Int) -> String {
        var sections = [metadata]
        for (name, text, truncated) in [("STDOUT", stdout, stdoutTruncated), ("STDERR", stderr, stderrTruncated)] {
            guard !text.isEmpty else { continue }
            let visible = String(text.prefix(outputLimit / 2))
            sections.append("\(name):\n\(visible)" + (truncated || visible.count < text.count ? "\n... (output truncated)" : ""))
        }
        if stdout.isEmpty && stderr.isEmpty { sections.append("(no output)") }
        if !observation.violations.isEmpty {
            sections.append("Observed sandbox filesystem denials:\n" + observation.violations
                .map { "\($0.operation): \($0.path)" }.joined(separator: "\n"))
        }
        if !observation.isComplete {
            sections.append("Sandbox diagnostics incomplete: " + (observation.diagnostic ?? "Some events may not have been collected."))
        }
        return sections.joined(separator: "\n\n")
    }
}
