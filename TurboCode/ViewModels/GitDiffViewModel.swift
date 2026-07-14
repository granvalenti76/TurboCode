import Foundation

// MARK: - Model Types

struct GitFileStatus: Identifiable, Hashable {
    let path: String
    let added: Int
    let removed: Int
    var id: String { path }
}

enum DiffLineType: Hashable, Sendable { case context; case added; case removed }

struct DiffLine: Identifiable, Hashable, Sendable {
    let id = UUID()
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let content: String
    let type: DiffLineType
}

struct FileDiffSection: Identifiable, Hashable {
    let path: String
    let added: Int
    let removed: Int
    let diffLines: [DiffLine]
    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }

    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Actor (identico a Codechat)

actor GitDiffService {
    enum GitError: LocalizedError {
        case notARepository
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notARepository: return "This directory is not a Git repository."
            case .commandFailed(let detail): return "Git command failed: \(detail)"
            }
        }
    }

    func isGitRepository(at directory: URL) -> Bool {
        shell("git", args: ["rev-parse", "--show-toplevel"], cwd: directory).exitCode == 0
    }

    func gitRoot(at directory: URL) -> URL? {
        let result = shell("git", args: ["rev-parse", "--show-toplevel"], cwd: directory)
        guard result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }

    // MARK: - Branch operations

    /// Returns the name of the currently checked-out branch, or nil if not a git repo.
    func currentBranch(at directory: URL) -> String? {
        let result = shell("git", args: ["rev-parse", "--abbrev-ref", "HEAD"], cwd: directory)
        guard result.exitCode == 0 else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    /// Returns all local branch names, or empty array if not a git repo.
    func allBranches(at directory: URL) -> [String] {
        let result = shell("git", args: ["branch", "--format=%(refname:short)"], cwd: directory)
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
    }

    /// Switch to the given branch. Returns true on success.
    @discardableResult
    func checkout(branch: String, at directory: URL) -> Bool {
        let result = shell("git", args: ["checkout", branch], cwd: directory)
        return result.exitCode == 0
    }

    func fetchChangedFiles(at url: URL) throws -> [GitFileStatus] {
        let unstaged = try parseNumstat(shell("git", args: ["diff", "--numstat"], cwd: url))
        let staged = try parseNumstat(shell("git", args: ["diff", "--cached", "--numstat"], cwd: url))
        let untracked = untrackedFiles(at: url).map { path in
            GitFileStatus(path: path, added: lineCount(at: url.appendingPathComponent(path)), removed: 0)
        }
        var merged: [String: GitFileStatus] = [:]
        for status in unstaged + staged + untracked {
            if let existing = merged[status.path] {
                merged[status.path] = GitFileStatus(
                    path: status.path,
                    added: existing.added + status.added,
                    removed: existing.removed + status.removed
                )
            } else {
                merged[status.path] = status
            }
        }
        return Array(merged.values).sorted { $0.path < $1.path }
    }

    func fetchDiff(for filePath: String, at url: URL) throws -> [DiffLine] {
        if untrackedFiles(at: url).contains(filePath) {
            let fileURL = url.appendingPathComponent(filePath)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            var lines = content.components(separatedBy: .newlines)
            if content.hasSuffix("\n") { lines.removeLast() }
            return lines.enumerated().map { index, content in
                DiffLine(oldLineNumber: nil, newLineNumber: index + 1, content: content, type: .added)
            }
        }

        let result = shell("git", args: ["diff", "--unified=9999", "--", filePath], cwd: url)
        guard result.exitCode == 0 else { throw GitError.commandFailed(result.stderr) }
        let stagedResult = shell("git", args: ["diff", "--cached", "--unified=9999", "--", filePath], cwd: url)
        let combined = result.stdout + (stagedResult.stdout.isEmpty ? "" : "\n" + stagedResult.stdout)
        return parseDiffOutput(combined)
    }

    // MARK: - Private

    private func parseNumstat(_ result: ShellResult) throws -> [GitFileStatus] {
        guard result.exitCode == 0 else { throw GitError.commandFailed(result.stderr) }
        return result.stdout
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 3, let added = Int(parts[0]), let removed = Int(parts[1]) else { return nil }
                return GitFileStatus(path: String(parts[2]), added: added, removed: removed)
            }
    }

    private func parseDiffOutput(_ output: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        let rawLines = output.components(separatedBy: .newlines)
        var oldLine: Int?; var newLine: Int?
        for raw in rawLines {
            guard !raw.hasPrefix("--- ") && !raw.hasPrefix("+++ ") && !raw.hasPrefix("diff --git") && !raw.hasPrefix("index ") else { continue }
            if raw.hasPrefix("@@") {
                if let match = raw.firstMatch(of: /@@[^@]*-(\d+)[^@]*\+(\d+)/) { oldLine = Int(match.1); newLine = Int(match.2) }
                continue
            }
            if raw.hasPrefix("+") {
                lines.append(DiffLine(oldLineNumber: nil, newLineNumber: newLine, content: String(raw.dropFirst()), type: .added))
                if let nl = newLine { newLine = nl + 1 }
            } else if raw.hasPrefix("-") {
                lines.append(DiffLine(oldLineNumber: oldLine, newLineNumber: nil, content: String(raw.dropFirst()), type: .removed))
                if let ol = oldLine { oldLine = ol + 1 }
            } else if raw.hasPrefix(" ") {
                lines.append(DiffLine(oldLineNumber: oldLine, newLineNumber: newLine, content: String(raw.dropFirst()), type: .context))
                if let ol = oldLine { oldLine = ol + 1 }; if let nl = newLine { newLine = nl + 1 }
            }
        }
        return lines
    }

    private func untrackedFiles(at url: URL) -> [String] {
        let result = shell("git", args: ["ls-files", "--others", "--exclude-standard"], cwd: url)
        guard result.exitCode == 0 else { return [] }
        return result.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private func lineCount(at url: URL) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else { return 0 }
        let separators = content.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        return content.hasSuffix("\n") ? separators : separators + 1
    }

    @discardableResult
    private func shell(_ command: String, args: [String], cwd: URL) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.currentDirectoryURL = cwd
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        do { try process.run(); process.waitUntilExit() }
        catch { return ShellResult(exitCode: -1, stdout: "", stderr: error.localizedDescription) }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ShellResult(
            exitCode: Int(process.terminationStatus),
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

private struct ShellResult { let exitCode: Int; let stdout: String; let stderr: String }

// MARK: - Factory helper (come Codechat)

extension FileDiffSection {
    static func fromGit(at projectURL: URL, service: GitDiffService) async -> [FileDiffSection]? {
        guard await service.isGitRepository(at: projectURL) else { return nil }

        let files: [GitFileStatus]
        do { files = try await service.fetchChangedFiles(at: projectURL) }
        catch { print("[FileDiffSection] git fetchChangedFiles failed: \(error)"); return nil }

        guard !files.isEmpty else { return [] }

        var sections: [FileDiffSection] = []
        for file in files {
            let lines: [DiffLine]
            do { lines = try await service.fetchDiff(for: file.path, at: projectURL) }
            catch {
                print("[FileDiffSection] git fetchDiff failed for \(file.path): \(error)")
                sections.append(FileDiffSection(path: file.path, added: file.added, removed: file.removed, diffLines: []))
                continue
            }
            sections.append(FileDiffSection(path: file.path, added: file.added, removed: file.removed, diffLines: lines))
        }
        return sections
    }
}
