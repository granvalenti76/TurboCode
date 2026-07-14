import Foundation
import FoundationModels

// MARK: - Diff Patch Tool

@Generable
struct DiffPatchArguments {
    /// A complete unified diff in git format. It may modify multiple text files.
    var patch: String
}

struct DiffPatchTool: Tool {
    typealias Arguments = DiffPatchArguments
    typealias Output = String

    let workspaceRoot: String
    private let service = DiffPatchService()

    var name: String { "diff_patch" }
    var description: String {
        """
        Apply a unified git diff to one or more text files in the current workspace.
        Prefer this tool over file_system write/append when editing existing code.
        The patch must include standard ---/+++ file headers and @@ hunks. Paths must
        be relative to the workspace and use the a/ and b/ git prefixes. The complete
        patch is validated with git apply --check before any file is changed.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: DiffPatchArguments) async throws -> String {
        let patch = arguments.patch.trimmingCharacters(in: .newlines) + "\n"

        let files: [DiffPatchFileChange]
        do {
            files = try DiffPatchParser.parse(patch, workspaceRoot: workspaceRoot)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        let id = UUID().uuidString
        do {
            try await service.check(patch: patch, workspaceRoot: workspaceRoot)
        } catch {
            await MainActor.run {
                ChatStore.shared?.beginDiffPatchBlock(
                    id: id,
                    patch: patch,
                    files: files,
                    status: .failed
                )
                ChatStore.shared?.updateDiffPatchBlock(
                    id: id,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
            }
            return "Error validating patch: \(error.localizedDescription)"
        }

        let autoRun = UserDefaults.standard.string(forKey: "approvalMode") == "Auto-run"
        let initialStatus: DiffPatchStatus = autoRun ? .running : .awaitingApproval
        await MainActor.run {
            ChatStore.shared?.beginDiffPatchBlock(
                id: id,
                patch: patch,
                files: files,
                status: initialStatus
            )
        }

        if autoRun {
            return await apply(patch: patch, files: files, id: id)
        }

        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        let summary = "Edit \(files.count) \(files.count == 1 ? "file" : "files") (+\(additions) -\(deletions))"
        await ToolApprovalRegistry.shared.register(PendingToolApproval(
            id: id,
            operation: "diffPatch",
            path: workspaceRoot,
            destination: nil,
            summary: summary,
            action: { [patch, files, id] in
                await apply(patch: patch, files: files, id: id)
            }
        ))

        return """
        TURBOCODE_APPROVAL_REQUIRED
        approval_id: \(id)
        operation: diffPatch
        path: \(workspaceRoot)
        summary: \(summary)
        """
    }

    private func apply(
        patch: String,
        files: [DiffPatchFileChange],
        id: String
    ) async -> String {
        await MainActor.run {
            ChatStore.shared?.updateDiffPatchBlock(id: id, status: .running)
        }

        do {
            try await service.apply(patch: patch, workspaceRoot: workspaceRoot)
            await MainActor.run {
                ChatStore.shared?.updateDiffPatchBlock(id: id, status: .applied)
            }
            let additions = files.reduce(0) { $0 + $1.additions }
            let deletions = files.reduce(0) { $0 + $1.deletions }
            return "Applied patch to \(files.count) file(s): +\(additions) -\(deletions)."
        } catch {
            await MainActor.run {
                ChatStore.shared?.updateDiffPatchBlock(
                    id: id,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
            }
            return "Error applying patch: \(error.localizedDescription)"
        }
    }
}

// MARK: - Patch Parsing

enum DiffPatchParser {
    nonisolated static func parse(_ patch: String, workspaceRoot: String) throws -> [DiffPatchFileChange] {
        guard !patch.contains("GIT binary patch") else {
            throw DiffPatchError.invalidPatch("Binary patches are not supported.")
        }

        var orderedPaths: [String] = []
        var counts: [String: (additions: Int, deletions: Int)] = [:]
        var oldPath: String?
        var currentPath: String?
        var insideHunk = false

        for line in patch.components(separatedBy: .newlines) {
            if line.hasPrefix("diff --git ") {
                insideHunk = false
                oldPath = nil
                currentPath = nil
                continue
            }
            if line.hasPrefix("--- ") {
                oldPath = normalizedPath(fromHeader: String(line.dropFirst(4)))
                insideHunk = false
                continue
            }
            if line.hasPrefix("+++ ") {
                let newPath = normalizedPath(fromHeader: String(line.dropFirst(4)))
                currentPath = newPath == nil ? oldPath : newPath
                if let currentPath, counts[currentPath] == nil {
                    orderedPaths.append(currentPath)
                    counts[currentPath] = (0, 0)
                }
                insideHunk = false
                continue
            }
            if line.hasPrefix("@@") {
                guard currentPath != nil else {
                    throw DiffPatchError.invalidPatch("A hunk is missing its file header.")
                }
                insideHunk = true
                continue
            }
            guard insideHunk, let currentPath else { continue }
            if line.hasPrefix("+") {
                counts[currentPath, default: (0, 0)].additions += 1
            } else if line.hasPrefix("-") {
                counts[currentPath, default: (0, 0)].deletions += 1
            }
        }

        guard !orderedPaths.isEmpty else {
            throw DiffPatchError.invalidPatch("No file changes were found in the unified diff.")
        }

        for path in orderedPaths {
            guard !(path as NSString).isAbsolutePath,
                  !path.split(separator: "/").contains("..") else {
                throw DiffPatchError.unsafePath(path)
            }
            _ = try WorkspacePathResolver.resolve(path, within: workspaceRoot)
        }

        return orderedPaths.map { path in
            let count = counts[path] ?? (0, 0)
            return DiffPatchFileChange(
                path: path,
                additions: count.additions,
                deletions: count.deletions
            )
        }
    }

    nonisolated private static func normalizedPath(fromHeader header: String) -> String? {
        let raw = header.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? header
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard unquoted != "/dev/null" else { return nil }
        if unquoted.hasPrefix("a/") || unquoted.hasPrefix("b/") {
            return String(unquoted.dropFirst(2))
        }
        return unquoted
    }
}

// MARK: - Git Executor

actor DiffPatchService {
    func check(patch: String, workspaceRoot: String, reverse: Bool = false) throws {
        try ensureGitRepository(workspaceRoot)
        let result = runGitApply(patch: patch, workspaceRoot: workspaceRoot, reverse: reverse, checkOnly: true)
        guard result.exitCode == 0 else {
            throw DiffPatchError.gitApplyFailed(result.error)
        }
    }

    func apply(patch: String, workspaceRoot: String, reverse: Bool = false) throws {
        try check(patch: patch, workspaceRoot: workspaceRoot, reverse: reverse)
        let result = runGitApply(patch: patch, workspaceRoot: workspaceRoot, reverse: reverse, checkOnly: false)
        guard result.exitCode == 0 else {
            throw DiffPatchError.gitApplyFailed(result.error)
        }
    }

    private func ensureGitRepository(_ workspaceRoot: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--show-toplevel"]
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw DiffPatchError.gitUnavailable(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            throw DiffPatchError.notGitRepository
        }
        let rootData = output.fileHandleForReading.readDataToEndOfFile()
        let gitRoot = String(data: rootData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedRoot = URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let resolvedGitRoot = gitRoot.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard resolvedGitRoot == expectedRoot else {
            throw DiffPatchError.workspaceIsNotGitRoot
        }
    }

    private func runGitApply(
        patch: String,
        workspaceRoot: String,
        reverse: Bool,
        checkOnly: Bool
    ) -> (exitCode: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var arguments = ["apply", "--recount", "--inaccurate-eof", "--whitespace=nowarn"]
        if checkOnly { arguments.append("--check") }
        if reverse { arguments.append("--reverse") }
        arguments.append("-")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workspaceRoot)

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(patch.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }

        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum DiffPatchError: LocalizedError {
    case invalidPatch(String)
    case unsafePath(String)
    case gitUnavailable(String)
    case notGitRepository
    case workspaceIsNotGitRoot
    case gitApplyFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPatch(let reason): return reason
        case .unsafePath(let path): return "Patch path '\(path)' is outside the workspace."
        case .gitUnavailable(let reason): return "Git is unavailable: \(reason)"
        case .notGitRepository: return "diff_patch requires a Git workspace."
        case .workspaceIsNotGitRoot: return "diff_patch requires the workspace folder to be the Git repository root."
        case .gitApplyFailed(let reason): return reason.isEmpty ? "git apply rejected the patch." : reason
        }
    }
}
