import Foundation
import FoundationModels

// MARK: - Diff Patch Tool

@Generable
struct AtomicTextEdit {
    /// Absolute or workspace-relative path of an existing UTF-8 text file.
    var filePath: String
    /// Exact, unique text currently present in the file, including whitespace.
    var oldText: String
    /// Replacement text. Use an empty string to delete oldText.
    var newText: String
}

@Generable
struct DiffPatchArguments {
    /// Preferred for existing files: exact text replacements converted into a Git patch by TurboCode.
    var edits: [AtomicTextEdit]?
    /// A complete unified diff. Use primarily for creating new files or when a patch is already available.
    var patch: String?
}

struct DiffPatchTool: Tool {
    typealias Arguments = DiffPatchArguments
    typealias Output = String

    let workspaceRoot: String
    private let service = DiffPatchService()

    var name: String { "diff_patch" }
    var description: String {
        """
        Atomically create or edit text files in a Git workspace and show the changes in a review widget.
        For existing files, prefer edits with exact oldText/newText replacements after using read_file.
        Keep oldText small but unique and copy whitespace exactly. TurboCode converts all replacements
        into one valid unified diff, then validates the complete change before touching any file.
        Use patch for new files or an already-available unified diff. Raw patches must contain standard
        ---/+++ headers and @@ hunks with a/ and b/ paths. New files use --- /dev/null.
        Provide either edits or patch, never both.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: DiffPatchArguments) async throws -> String {
        let patch: String
        let edits = arguments.edits ?? []
        let usesStructuredEdits = !edits.isEmpty
        let rawPatch = arguments.patch?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard edits.isEmpty || rawPatch.isEmpty else {
            return "Error: Provide either structured edits or a unified patch, not both."
        }

        if !edits.isEmpty {
            do {
                patch = try await service.makePatch(
                    edits: edits,
                    workspaceRoot: workspaceRoot
                )
            } catch {
                return "Error preparing edits: \(error.localizedDescription) Re-read the affected range and retry with exact current text."
            }
        } else if !rawPatch.isEmpty {
            patch = normalizedRawPatch(rawPatch)
        } else {
            return "Error: At least one structured edit or a unified patch is required."
        }

        let files: [DiffPatchFileChange]
        do {
            files = try DiffPatchParser.parse(patch, workspaceRoot: workspaceRoot)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        let id = UUID().uuidString
        do {
            try await service.check(
                patch: patch,
                workspaceRoot: workspaceRoot,
                tolerateInaccurateEOF: !usesStructuredEdits
            )
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

        await MainActor.run {
            ChatStore.shared?.beginDiffPatchBlock(
                id: id,
                patch: patch,
                files: files,
                status: .running
            )
        }

        return await apply(
            patch: patch,
            files: files,
            id: id,
            tolerateInaccurateEOF: !usesStructuredEdits
        )
    }

    private func normalizedRawPatch(_ value: String) -> String {
        var lines = value.components(separatedBy: .newlines)
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    private func apply(
        patch: String,
        files: [DiffPatchFileChange],
        id: String,
        tolerateInaccurateEOF: Bool
    ) async -> String {
        await MainActor.run {
            ChatStore.shared?.updateDiffPatchBlock(id: id, status: .running)
        }

        do {
            try await service.apply(
                patch: patch,
                workspaceRoot: workspaceRoot,
                tolerateInaccurateEOF: tolerateInaccurateEOF
            )
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

actor DiffPatchService: DiffPatchApplying {
    private struct NativeFileSnapshot {
        let url: URL
        let contents: Data?
    }

    func makePatch(edits: [AtomicTextEdit], workspaceRoot: String) throws -> String {
        guard !edits.isEmpty else {
            throw DiffPatchError.invalidEdit("No edits were provided.")
        }

        let rootURL = URL(fileURLWithPath: workspaceRoot)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var orderedPaths: [String] = []
        var originalContents: [String: String] = [:]
        var updatedContents: [String: String] = [:]

        for (index, edit) in edits.enumerated() {
            let fileURL = try WorkspacePathResolver.resolve(edit.filePath, within: workspaceRoot)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw DiffPatchError.invalidEdit(
                    "Edit \(index + 1) targets a missing file. Use a raw new-file patch for '\(edit.filePath)'."
                )
            }
            guard !edit.oldText.isEmpty else {
                throw DiffPatchError.invalidEdit(
                    "Edit \(index + 1) has empty oldText. Include a unique existing anchor."
                )
            }

            let relativePath = String(fileURL.path.dropFirst(rootURL.path.count + 1))
            if originalContents[relativePath] == nil {
                let content: String
                do {
                    content = try String(contentsOf: fileURL, encoding: .utf8)
                } catch {
                    throw DiffPatchError.invalidEdit("'\(relativePath)' is not readable UTF-8 text.")
                }
                orderedPaths.append(relativePath)
                originalContents[relativePath] = content
                updatedContents[relativePath] = content
            }

            guard var current = updatedContents[relativePath] else { continue }
            let matches = exactRanges(of: edit.oldText, in: current)
            guard matches.count == 1, let range = matches.first else {
                let reason = matches.isEmpty
                    ? "oldText was not found"
                    : "oldText matched \(matches.count) locations"
                throw DiffPatchError.invalidEdit(
                    "Edit \(index + 1) for '\(relativePath)' is stale or ambiguous: \(reason)."
                )
            }
            current.replaceSubrange(range, with: edit.newText)
            updatedContents[relativePath] = current
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var generatedPatches: [String] = []
        for (index, path) in orderedPaths.enumerated() {
            guard let original = originalContents[path],
                  let updated = updatedContents[path],
                  original != updated else { continue }

            let oldURL = temporaryDirectory.appendingPathComponent("\(index)-old")
            let newURL = temporaryDirectory.appendingPathComponent("\(index)-new")
            try original.write(to: oldURL, atomically: true, encoding: .utf8)
            try updated.write(to: newURL, atomically: true, encoding: .utf8)
            generatedPatches.append(try unifiedDiff(
                oldURL: oldURL,
                newURL: newURL,
                relativePath: path,
                temporaryDirectory: temporaryDirectory,
                index: index
            ))
        }

        guard !generatedPatches.isEmpty else {
            throw DiffPatchError.invalidEdit("The replacements would not change any file.")
        }
        return generatedPatches.joined(separator: "").trimmingCharacters(in: .newlines) + "\n"
    }

    func check(
        patch: String,
        workspaceRoot: String,
        reverse: Bool = false,
        tolerateInaccurateEOF: Bool = false
    ) throws {
        let result: (exitCode: Int32, error: String)
        if usesGitApply(workspaceRoot) {
            result = runGitApply(
                patch: patch,
                workspaceRoot: workspaceRoot,
                reverse: reverse,
                checkOnly: true,
                tolerateInaccurateEOF: tolerateInaccurateEOF
            )
        } else {
            let files = try DiffPatchParser.parse(patch, workspaceRoot: workspaceRoot)
            let createdDirectories = try prepareParentDirectories(
                for: files,
                workspaceRoot: workspaceRoot
            )
            defer { removeEmptyDirectories(createdDirectories) }
            result = runNativePatch(
                patch: patch,
                workspaceRoot: workspaceRoot,
                reverse: reverse,
                checkOnly: true
            )
        }
        guard result.exitCode == 0 else {
            throw DiffPatchError.patchApplyFailed(result.error)
        }
    }

    private func exactRanges(of needle: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    private func unifiedDiff(
        oldURL: URL,
        newURL: URL,
        relativePath: String,
        temporaryDirectory: URL,
        index: Int
    ) throws -> String {
        let outputURL = temporaryDirectory.appendingPathComponent("\(index)-patch")
        let errorURL = temporaryDirectory.appendingPathComponent("\(index)-error")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = [
            "-u",
            "--label", "a/\(relativePath)",
            "--label", "b/\(relativePath)",
            oldURL.path,
            newURL.path
        ]
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? outputHandle.close()
            try? errorHandle.close()
            throw DiffPatchError.diffGenerationFailed(error.localizedDescription)
        }
        try? outputHandle.close()
        try? errorHandle.close()

        guard process.terminationStatus == 1 else {
            let message = (try? String(contentsOf: errorURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DiffPatchError.diffGenerationFailed(
                message.isEmpty ? "diff exited with status \(process.terminationStatus)." : message
            )
        }
        return try String(contentsOf: outputURL, encoding: .utf8)
    }

    func apply(
        patch: String,
        workspaceRoot: String,
        reverse: Bool = false,
        tolerateInaccurateEOF: Bool = false
    ) throws {
        if usesGitApply(workspaceRoot) {
            try check(
                patch: patch,
                workspaceRoot: workspaceRoot,
                reverse: reverse,
                tolerateInaccurateEOF: tolerateInaccurateEOF
            )
            let result = runGitApply(
                patch: patch,
                workspaceRoot: workspaceRoot,
                reverse: reverse,
                checkOnly: false,
                tolerateInaccurateEOF: tolerateInaccurateEOF
            )
            guard result.exitCode == 0 else {
                throw DiffPatchError.patchApplyFailed(result.error)
            }
            return
        }

        try applyNativePatch(patch, workspaceRoot: workspaceRoot, reverse: reverse)
    }

    private func usesGitApply(_ workspaceRoot: String) -> Bool {
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
            return false
        }
        guard process.terminationStatus == 0 else { return false }
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
        return resolvedGitRoot == expectedRoot
    }

    private func applyNativePatch(
        _ patch: String,
        workspaceRoot: String,
        reverse: Bool
    ) throws {
        let files = try DiffPatchParser.parse(patch, workspaceRoot: workspaceRoot)
        let snapshots = try files.map { file in
            let url = try WorkspacePathResolver.resolve(file.path, within: workspaceRoot)
            let contents = FileManager.default.fileExists(atPath: url.path)
                ? try Data(contentsOf: url)
                : nil
            return NativeFileSnapshot(url: url, contents: contents)
        }
        let createdDirectories = try prepareParentDirectories(
            for: files,
            workspaceRoot: workspaceRoot
        )

        let checkResult = runNativePatch(
            patch: patch,
            workspaceRoot: workspaceRoot,
            reverse: reverse,
            checkOnly: true
        )
        guard checkResult.exitCode == 0 else {
            removeEmptyDirectories(createdDirectories)
            throw DiffPatchError.patchApplyFailed(checkResult.error)
        }

        let applyResult = runNativePatch(
            patch: patch,
            workspaceRoot: workspaceRoot,
            reverse: reverse,
            checkOnly: false
        )
        guard applyResult.exitCode == 0 else {
            restore(snapshots)
            removeEmptyDirectories(createdDirectories)
            throw DiffPatchError.patchApplyFailed(applyResult.error)
        }
    }

    private func prepareParentDirectories(
        for files: [DiffPatchFileChange],
        workspaceRoot: String
    ) throws -> [URL] {
        var missing = Set<URL>()
        let root = URL(fileURLWithPath: workspaceRoot).standardizedFileURL
        for file in files {
            let url = try WorkspacePathResolver.resolve(file.path, within: workspaceRoot)
            var directory = url.deletingLastPathComponent()
            while directory.path != root.path,
                  !FileManager.default.fileExists(atPath: directory.path) {
                missing.insert(directory)
                directory.deleteLastPathComponent()
            }
        }
        let ordered = missing.sorted {
            $0.pathComponents.count < $1.pathComponents.count
        }
        for directory in ordered {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        return ordered
    }

    private func removeEmptyDirectories(_ directories: [URL]) {
        for directory in directories.reversed() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func restore(_ snapshots: [NativeFileSnapshot]) {
        for snapshot in snapshots {
            if let contents = snapshot.contents {
                try? contents.write(to: snapshot.url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: snapshot.url.path) {
                try? FileManager.default.removeItem(at: snapshot.url)
            }
        }
    }

    private func runNativePatch(
        patch: String,
        workspaceRoot: String,
        reverse: Bool,
        checkOnly: Bool
    ) -> (exitCode: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/patch")
        var arguments = ["-p1", "-f", "-s", "-E"]
        if checkOnly { arguments.append("-C") }
        if reverse { arguments.append("-R") }
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
            // BSD patch treats a space as the end of an unquoted header path unless
            // the path is terminated by a tab. Generated patches omit timestamps,
            // so add that delimiter to keep workspace paths with spaces intact.
            let nativePatch = patchWithDelimitedHeaderPaths(patch)
            try input.fileHandleForWriting.write(contentsOf: Data(nativePatch.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let detail = [stdout, stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, detail)
    }

    private func patchWithDelimitedHeaderPaths(_ patch: String) -> String {
        patch.components(separatedBy: .newlines).map { line in
            guard (line.hasPrefix("--- ") || line.hasPrefix("+++ ")),
                  !line.contains("\t") else { return line }
            return line + "\t"
        }.joined(separator: "\n")
    }

    private func runGitApply(
        patch: String,
        workspaceRoot: String,
        reverse: Bool,
        checkOnly: Bool,
        tolerateInaccurateEOF: Bool
    ) -> (exitCode: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var arguments = ["apply", "--recount", "--whitespace=nowarn"]
        if tolerateInaccurateEOF && !reverse { arguments.append("--inaccurate-eof") }
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
    case invalidEdit(String)
    case revisionConflict(String)
    case unsafePath(String)
    case gitUnavailable(String)
    case notGitRepository
    case workspaceIsNotGitRoot
    case gitApplyFailed(String)
    case patchApplyFailed(String)
    case diffGenerationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPatch(let reason): return reason
        case .invalidEdit(let reason): return reason
        case .revisionConflict(let path):
            return "Revision mismatch for '\(path)'."
        case .unsafePath(let path): return "Patch path '\(path)' is outside the workspace."
        case .gitUnavailable(let reason): return "Git is unavailable: \(reason)"
        case .notGitRepository: return "diff_patch requires a Git workspace."
        case .workspaceIsNotGitRoot: return "diff_patch requires the workspace folder to be the Git repository root."
        case .gitApplyFailed(let reason): return reason.isEmpty ? "git apply rejected the patch." : reason
        case .patchApplyFailed(let reason): return reason.isEmpty ? "The patch could not be applied." : reason
        case .diffGenerationFailed(let reason): return "Could not generate a unified diff: \(reason)"
        }
    }
}
