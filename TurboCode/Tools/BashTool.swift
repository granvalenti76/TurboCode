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
    private let pluginRoot: String
    private let sdkRoot: String
    private let requestApproval: @Sendable (PendingToolApproval) async -> String
    private let service = BashService()

    init(
        workspaceRoot: String,
        executionPolicy: ExecutionPolicy = ExecutionPolicy(),
        taskScope: AgentTaskPathScope? = nil,
        // Bash runs from non-main-actor workers too; derive the same canonical
        // locations without touching the MainActor-isolated configuration object.
        pluginRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode/plugins", isDirectory: true).path,
        sdkRoot: String = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode/sdk", isDirectory: true).path,
        requestApproval: @escaping @Sendable (PendingToolApproval) async -> String = {
            await ToolApprovalRegistry.shared.request($0)
        }
    ) {
        self.workspaceRoot = workspaceRoot
        self.executionPolicy = executionPolicy
        self.taskScope = taskScope
        self.pluginRoot = pluginRoot
        self.sdkRoot = sdkRoot
        self.requestApproval = requestApproval
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(
            workspaceRoot: workspaceRoot,
            executionPolicy: executionPolicy,
            taskScope: scope,
            pluginRoot: pluginRoot,
            sdkRoot: sdkRoot,
            requestApproval: requestApproval
        )
    }

    var name: String { "bash" }
    var description: String {
        """
        Run a zsh command from the workspace root. Use list_workspace (Browse
        Directory) for directory listings, read_file for focused file ranges,
        and edit_file for source or text changes. Use git for every Git
        operation. Check pwd before any
        destructive relative command.
        If the host sandbox blocks an external path, TurboCode asks the user and
        reruns this exact command after approval; never invent an approval token.
        Output and execution time are bounded.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: BashArguments) async throws -> String {
        if let taskScope, !taskScope.isWorkspaceWide {
            return "Error: bash requires an entire-workspace task scope because command paths cannot be safely narrowed."
        }
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
            allowNetworkAccess: executionPolicy.allowNetworkAccess,
            pluginRoot: pluginRoot,
            sdkRoot: sdkRoot,
            requestApproval: requestApproval
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
        allowNetworkAccess: Bool,
        pluginRoot: String,
        sdkRoot: String,
        requestApproval: @Sendable (PendingToolApproval) async -> String
    ) async -> String {
        // Seatbelt makes the first decision. Only its denial can open a host-owned
        // approval; no approval text produced by the model is parsed or trusted.
        let result = execute(
            command: command,
            workspaceRoot: workspaceRoot,
            timeoutSeconds: timeoutSeconds,
            outputLimit: outputLimit,
            allowNetworkAccess: allowNetworkAccess,
            pluginRoot: pluginRoot,
            sdkRoot: sdkRoot,
            allowExternalAccess: false
        )
        guard Self.isSandboxDenial(result) else { return result }

        let authorized = await WorkspaceAccessGate.shared.authorizeExternalExecution(
            tool: "Bash",
            workspaceRoot: workspaceRoot,
            targetDescription: "filesystem paths requested by this command",
            command: command,
            requestApproval: requestApproval
        )
        guard authorized else {
            return "External filesystem access denied by the user. The command was not rerun."
        }
        return execute(
            command: command,
            workspaceRoot: workspaceRoot,
            timeoutSeconds: timeoutSeconds,
            outputLimit: outputLimit,
            allowNetworkAccess: allowNetworkAccess,
            pluginRoot: pluginRoot,
            sdkRoot: sdkRoot,
            allowExternalAccess: true
        )
    }

    private func execute(
        command: String,
        workspaceRoot: String,
        timeoutSeconds: Int,
        outputLimit: Int,
        allowNetworkAccess: Bool,
        pluginRoot: String,
        sdkRoot: String,
        allowExternalAccess: Bool
    ) -> String {
        let resolvedWorkspace = try? WorkspacePathResolver.resolve(".", within: workspaceRoot)
        let activeWorkspaceURL = resolvedWorkspace.flatMap { Self.isDirectory($0) ? $0 : nil }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Bash-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = outputDirectory.appendingPathComponent("stderr.txt")
        let binDirectory = outputDirectory.appendingPathComponent("bin", isDirectory: true)
        let homeDirectory = outputDirectory.appendingPathComponent("home", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
            try installSwiftWrapper(in: binDirectory)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        } catch {
            return "Error preparing command output: \(error.localizedDescription)"
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
            return "Error opening command output: \(error.localizedDescription)"
        }

        let process = Process()
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-p",
            sandboxProfile(
                workspacePath: workingDirectoryURL.path,
                outputPath: outputDirectory.path,
                allowNetworkAccess: allowNetworkAccess,
                nodeRuntimeRoot: nodeRuntimeRoot,
                allowExternalAccess: allowExternalAccess
            ),
            "/bin/zsh",
            "-fc",
            command
        ]
        process.currentDirectoryURL = workingDirectoryURL
        var commandEnvironment = ProcessInfo.processInfo.environment.merging([
            "PWD": workingDirectoryURL.path,
            "TMPDIR": outputDirectory.path,
            "HOME": homeDirectory.path,
            "XDG_CACHE_HOME": homeDirectory.appendingPathComponent(".cache").path,
            "TURBOCODE_PLUGIN_ROOT": pluginRoot,
            "TURBOCODE_SDK_ROOT": sdkRoot,
            "TURBOCODE_SDK_PACKAGE": sdkPackage,
            "PATH": "\(binDirectory.path):\(commandPath)",
            "GIT_CONFIG_GLOBAL": "/dev/null"
        ]) { _, new in new }
        if let nodeExecutable {
            commandEnvironment["TURBOCODE_NODE_PATH"] = nodeExecutable.path
        }
        process.environment = commandEnvironment
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
            "Working directory: \(workingDirectoryURL.path)",
            activeWorkspaceURL == nil
                ? "Workspace unavailable: relative paths use a disposable directory."
                : "Workspace: \(activeWorkspaceURL!.path)",
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

    private static func isSandboxDenial(_ result: String) -> Bool {
        let normalized = result.lowercased()
        return normalized.contains("operation not permitted")
            || normalized.contains("permission denied")
            || normalized.contains("sandbox") && normalized.contains("deny")
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private func installSwiftWrapper(in directory: URL) throws {
        let url = directory.appendingPathComponent("swift")
        let script = """
        #!/bin/zsh
        has_argument() {
          local target="$1"
          shift
          for argument in "$@"; do
            if [[ "$argument" == "$target" || "$argument" == "$target="* ]]; then
              return 0
            fi
          done
          return 1
        }

        case "$1" in
          build|test|run|package)
            subcommand="$1"
            shift
            injected_arguments=()
            has_argument --disable-sandbox "$@" || injected_arguments+=(--disable-sandbox)
            has_argument --cache-path "$@" || injected_arguments+=(--cache-path "$HOME/.swiftpm/cache")
            has_argument --config-path "$@" || injected_arguments+=(--config-path "$HOME/.swiftpm/configuration")
            has_argument --security-path "$@" || injected_arguments+=(--security-path "$HOME/.swiftpm/security")
            exec /usr/bin/swift "$subcommand" "${injected_arguments[@]}" "$@"
            ;;
          *)
            exec /usr/bin/swift "$@"
            ;;
        esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func sandboxProfile(
        workspacePath: String,
        outputPath: String,
        allowNetworkAccess: Bool,
        nodeRuntimeRoot: String?,
        allowExternalAccess: Bool
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
                                (subpath "\(output)"))))))
            (deny file-write*)
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
