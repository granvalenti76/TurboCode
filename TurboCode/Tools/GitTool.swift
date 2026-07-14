import Foundation
import FoundationModels
import Darwin

@Generable
struct GitArguments {
    /// Git operation to perform.
    @Guide(.anyOf([
        "init", "status", "diff", "stagedDiff", "log", "branches", "remotes",
        "createBranch", "switchBranch", "stage", "stageAll", "unstage",
        "unstageAll", "commit", "fetch", "pull", "push", "merge", "rebase",
        "mergeAbort", "rebaseAbort", "discard", "clean", "resetHard",
        "deleteBranch", "forceDeleteBranch", "forcePush"
    ]))
    var operation: String
    /// Workspace-relative file paths for stage, unstage, or discard.
    var paths: [String]?
    /// Branch name for init, create, switch, merge, rebase, delete, push, or reset target.
    var branch: String?
    /// Commit message for commit.
    var message: String?
    /// Remote name for fetch, pull, or push. Defaults to origin.
    var remote: String?
    /// Maximum entries for log. Defaults to 20 and is capped at 100.
    var limit: Int?
}

struct GitTool: Tool {
    typealias Arguments = GitArguments
    typealias Output = String

    let workspaceRoot: String
    let policy: GitPolicy
    let executionPolicy: ExecutionPolicy
    private let service = StructuredGitService()

    var name: String { "git" }
    var description: String {
        """
        Initialize, inspect, and manage Git in the active workspace.
        Use init when the workspace is not a repository; it creates the repository
        directly with main as the default initial branch.
        Use status, diff, stagedDiff, log, branches, and remotes for inspection.
        Use stage, stageAll, unstage, unstageAll, commit, createBranch,
        switchBranch, merge, rebase, fetch, pull, and push for normal workflows.
        discard, clean, resetHard, forceDeleteBranch, rebase, and forcePush may
        require user approval because they can discard work or rewrite history.
        Paths must remain inside the workspace. Never use bash for an operation
        supported by this tool.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: GitArguments) async throws -> String {
        guard let operation = GitOperation(rawValue: arguments.operation) else {
            return "Error: Unsupported Git operation '\(arguments.operation)'."
        }
        if operation != .initialize {
            guard await service.isRepository(workspaceRoot: workspaceRoot) else {
                return "Error: The active workspace is not a Git repository. Use the init operation to initialize it."
            }
        }

        let command: GitCommand
        do {
            command = try makeCommand(operation: operation, arguments: arguments)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        if command.requiresNetwork && !executionPolicy.allowNetworkAccess {
            return "Error: Command network access is disabled in Agent Settings."
        }
        if command.writesRemote && !policy.allowsRemoteWrites {
            return "Error: Remote Git writes are disabled by Agent Tuning."
        }
        if operation == .commit && !policy.allowsCommits {
            return "Error: Git commits are disabled by Agent Tuning."
        }

        if command.isDestructive && policy.confirmsDestructiveOperations {
            return await requestApproval(operation: operation, command: command)
        }

        let result = await service.run(
            command.arguments,
            workspaceRoot: workspaceRoot,
            timeoutSeconds: command.timeoutSeconds(executionPolicy),
            outputLimit: executionPolicy.maximumToolOutputCharacters
        )
        if operation == .commit,
           result.succeeded,
           let receipt = await service.latestCommitReceipt(workspaceRoot: workspaceRoot) {
            await ChatStore.shared?.presentGitCommit(receipt)
        }
        await refreshGitUIIfNeeded(result: result, mutatesRepository: command.mutatesRepository)
        return result.rendered
    }

    private func makeCommand(
        operation: GitOperation,
        arguments: GitArguments
    ) throws -> GitCommand {
        let remote = nonEmpty(arguments.remote) ?? "origin"
        let branch = nonEmpty(arguments.branch)
        let paths = try relativePaths(arguments.paths ?? [])

        switch operation {
        case .initialize:
            return GitCommand(
                ["init", "--initial-branch", branch ?? "main"],
                mutates: true
            )
        case .status:
            return GitCommand(["status", "--short", "--branch"])
        case .diff:
            return GitCommand(["diff", "--no-ext-diff", "--unified=3"] + pathspec(paths))
        case .stagedDiff:
            return GitCommand(["diff", "--cached", "--no-ext-diff", "--unified=3"] + pathspec(paths))
        case .log:
            let limit = min(max(arguments.limit ?? 20, 1), 100)
            return GitCommand([
                "log", "--max-count=\(limit)", "--date=short",
                "--pretty=format:%h%x09%ad%x09%an%x09%s"
            ])
        case .branches:
            return GitCommand(["branch", "--all", "--verbose", "--no-abbrev"])
        case .remotes:
            return GitCommand(["remote", "--verbose"])
        case .createBranch:
            return GitCommand(["switch", "--create", try required(branch, "branch")], mutates: true)
        case .switchBranch:
            return GitCommand(["switch", try required(branch, "branch")], mutates: true)
        case .stage:
            return GitCommand(["add", "--"] + (try requiredPaths(paths)), mutates: true)
        case .stageAll:
            return GitCommand(["add", "--all"], mutates: true)
        case .unstage:
            return GitCommand(["restore", "--staged", "--"] + (try requiredPaths(paths)), mutates: true)
        case .unstageAll:
            return GitCommand(["reset", "--mixed"], mutates: true)
        case .commit:
            return GitCommand(["commit", "--message", try required(nonEmpty(arguments.message), "message")], mutates: true)
        case .fetch:
            return GitCommand(["fetch", remote, "--prune"], mutates: true, network: true)
        case .pull:
            var values = ["pull", "--ff-only", remote]
            if let branch { values.append(branch) }
            return GitCommand(values, mutates: true, network: true)
        case .push:
            return GitCommand(
                ["push", "--set-upstream", remote, branch ?? "HEAD"],
                mutates: true,
                network: true,
                remoteWrite: true
            )
        case .merge:
            return GitCommand(["merge", "--no-edit", try required(branch, "branch")], mutates: true)
        case .rebase:
            return GitCommand(
                ["rebase", try required(branch, "branch")],
                mutates: true,
                destructive: true
            )
        case .mergeAbort:
            return GitCommand(["merge", "--abort"], mutates: true)
        case .rebaseAbort:
            return GitCommand(["rebase", "--abort"], mutates: true)
        case .discard:
            return GitCommand(
                ["restore", "--worktree", "--"] + (try requiredPaths(paths)),
                mutates: true,
                destructive: true
            )
        case .clean:
            return GitCommand(["clean", "--force", "--dirs"], mutates: true, destructive: true)
        case .resetHard:
            return GitCommand(["reset", "--hard", branch ?? "HEAD"], mutates: true, destructive: true)
        case .deleteBranch:
            return GitCommand(["branch", "--delete", try required(branch, "branch")], mutates: true)
        case .forceDeleteBranch:
            return GitCommand(
                ["branch", "--delete", "--force", try required(branch, "branch")],
                mutates: true,
                destructive: true
            )
        case .forcePush:
            return GitCommand(
                ["push", "--force-with-lease", remote, branch ?? "HEAD"],
                mutates: true,
                network: true,
                remoteWrite: true,
                destructive: true
            )
        }
    }

    private func requestApproval(operation: GitOperation, command: GitCommand) async -> String {
        let id = UUID().uuidString
        let summary = approvalSummary(for: operation, arguments: command.arguments)
        let service = service
        let workspaceRoot = workspaceRoot
        let outputLimit = executionPolicy.maximumToolOutputCharacters
        let timeout = command.timeoutSeconds(executionPolicy)
        let request = PendingToolApproval(
            id: id,
            operation: "git.\(operation.rawValue)",
            path: workspaceRoot,
            destination: nil,
            summary: summary,
            action: {
                let result = await service.run(
                    command.arguments,
                    workspaceRoot: workspaceRoot,
                    timeoutSeconds: timeout,
                    outputLimit: outputLimit
                )
                if result.succeeded && command.mutatesRepository {
                    await ChatStore.shared?.refreshGitAfterToolMutation()
                }
                return result.rendered
            }
        )
        await ToolApprovalRegistry.shared.register(request)

        return """
        TURBOCODE_APPROVAL_REQUIRED
        approval_id: \(id)
        operation: git.\(operation.rawValue)
        path: \(workspaceRoot)
        summary: \(summary)
        """
    }

    private func refreshGitUIIfNeeded(result: GitCommandResult, mutatesRepository: Bool) async {
        guard result.succeeded, mutatesRepository else { return }
        await ChatStore.shared?.refreshGitAfterToolMutation()
    }

    private func relativePaths(_ values: [String]) throws -> [String] {
        let root = URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return try values.map { value in
            let resolved = try WorkspacePathResolver.resolve(value, within: workspaceRoot)
            guard resolved.path != root.path else { return "." }
            return String(resolved.path.dropFirst(root.path.count + 1))
        }
    }

    private func requiredPaths(_ paths: [String]) throws -> [String] {
        guard !paths.isEmpty else { throw GitToolError.missingArgument("paths") }
        return paths
    }

    private func required<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw GitToolError.missingArgument(name) }
        return value
    }

    private func nonEmpty(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func pathspec(_ paths: [String]) -> [String] {
        paths.isEmpty ? [] : ["--"] + paths
    }

    private func approvalSummary(for operation: GitOperation, arguments: [String]) -> String {
        switch operation {
        case .discard: "Discard uncommitted changes in the selected paths."
        case .clean: "Permanently delete untracked files and directories."
        case .resetHard: "Reset tracked files and repository state with git reset --hard."
        case .forceDeleteBranch: "Force-delete the selected local branch."
        case .rebase: "Rewrite local commits by rebasing the current branch."
        case .forcePush: "Rewrite the remote branch using --force-with-lease."
        default: "Run Git operation: \(arguments.joined(separator: " "))."
        }
    }
}

private enum GitOperation: String {
    case initialize = "init"
    case status, diff, stagedDiff, log, branches, remotes
    case createBranch, switchBranch, stage, stageAll, unstage, unstageAll, commit
    case fetch, pull, push, merge, rebase, mergeAbort, rebaseAbort
    case discard, clean, resetHard, deleteBranch, forceDeleteBranch, forcePush
}

private struct GitCommand: Sendable {
    let arguments: [String]
    let mutatesRepository: Bool
    let requiresNetwork: Bool
    let writesRemote: Bool
    let isDestructive: Bool

    nonisolated init(
        _ arguments: [String],
        mutates: Bool = false,
        network: Bool = false,
        remoteWrite: Bool = false,
        destructive: Bool = false
    ) {
        self.arguments = arguments
        self.mutatesRepository = mutates
        self.requiresNetwork = network
        self.writesRemote = remoteWrite
        self.isDestructive = destructive
    }

    nonisolated func timeoutSeconds(_ policy: ExecutionPolicy) -> Int {
        requiresNetwork ? policy.maximumCommandTimeoutSeconds : policy.defaultCommandTimeoutSeconds
    }
}

private enum GitToolError: LocalizedError {
    case missingArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name): "'\(name)' is required for this Git operation."
        }
    }
}

private struct GitCommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    nonisolated var succeeded: Bool { exitCode == 0 && !timedOut }

    nonisolated var rendered: String {
        var sections = ["Git exit code: \(exitCode)"]
        if timedOut { sections.append("Git command timed out.") }
        if !stdout.isEmpty { sections.append("STDOUT:\n\(stdout)") }
        if !stderr.isEmpty { sections.append("STDERR:\n\(stderr)") }
        if stdout.isEmpty && stderr.isEmpty { sections.append("Git operation completed with no output.") }
        return sections.joined(separator: "\n\n")
    }
}

private actor StructuredGitService {
    func latestCommitReceipt(workspaceRoot: String) -> GitCommitBlock? {
        let metadata = runSynchronously(
            ["show", "--quiet", "--format=%H%x00%h%x00%s", "HEAD"],
            workspaceRoot: workspaceRoot,
            timeoutSeconds: 10,
            outputLimit: 8_000
        )
        guard metadata.succeeded else { return nil }
        let fields = metadata.stdout.split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }

        let hash = String(fields[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let shortHash = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty, !shortHash.isEmpty else { return nil }

        let branchResult = runSynchronously(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            workspaceRoot: workspaceRoot,
            timeoutSeconds: 10,
            outputLimit: 1_000
        )
        let symbolicBranch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = branchResult.succeeded && !symbolicBranch.isEmpty
            ? symbolicBranch
            : "detached@\(shortHash)"

        let stats = runSynchronously(
            ["diff-tree", "--root", "--no-commit-id", "--numstat", "-r", "HEAD"],
            workspaceRoot: workspaceRoot,
            timeoutSeconds: 10,
            outputLimit: 30_000
        )
        let files = stats.succeeded ? parseNumstat(stats.stdout) : []
        return GitCommitBlock(
            workspaceRoot: workspaceRoot,
            hash: hash,
            shortHash: shortHash,
            message: message,
            branch: branch,
            files: files,
            status: .committed,
            errorMessage: nil
        )
    }

    func isRepository(workspaceRoot: String) -> Bool {
        let result = runSynchronously(
            ["rev-parse", "--is-inside-work-tree"],
            workspaceRoot: workspaceRoot,
            timeoutSeconds: 10,
            outputLimit: 1_000
        )
        return result.succeeded
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    func run(
        _ arguments: [String],
        workspaceRoot: String,
        timeoutSeconds: Int,
        outputLimit: Int
    ) -> GitCommandResult {
        runSynchronously(
            arguments,
            workspaceRoot: workspaceRoot,
            timeoutSeconds: timeoutSeconds,
            outputLimit: outputLimit
        )
    }

    private func runSynchronously(
        _ arguments: [String],
        workspaceRoot: String,
        timeoutSeconds: Int,
        outputLimit: Int
    ) -> GitCommandResult {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Git-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = outputDirectory.appendingPathComponent("stderr.txt")
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        } catch {
            return GitCommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            return GitCommandResult(exitCode: -1, stdout: "", stderr: "Unable to open Git output files.", timedOut: false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_PAGER": "cat",
            "GIT_EDITOR": "true",
            "GIT_MERGE_AUTOEDIT": "no",
            "LC_ALL": "C"
        ]) { _, new in new }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            return GitCommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if timedOut {
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? stdoutHandle.close()
        try? stderrHandle.close()

        return GitCommandResult(
            exitCode: process.terminationStatus,
            stdout: readOutput(stdoutURL, limit: outputLimit / 2),
            stderr: readOutput(stderrURL, limit: outputLimit / 2),
            timedOut: timedOut
        )
    }

    private func readOutput(_ url: URL, limit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
        let truncated = data.count > limit
        let value = String(decoding: data.prefix(limit), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        return truncated ? value + "\n... (truncated)" : value
    }

    private func parseNumstat(_ output: String) -> [GitCommitFileChange] {
        output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return GitCommitFileChange(
                path: String(fields[2]),
                additions: Int(fields[0]) ?? 0,
                deletions: Int(fields[1]) ?? 0
            )
        }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
