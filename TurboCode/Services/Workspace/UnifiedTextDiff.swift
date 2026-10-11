import Foundation

/// Builds review artifacts for two versions of one text file.
///
/// Cowork shows diffs it never applies: a VM file write and an export
/// conflict are presented with the existing `DiffPatchReviewSheet`, which only
/// needs immutable before/after snapshots and line counts. The unified patch is
/// produced by `/usr/bin/diff -u`, the same tool `ApplyEditsTool` uses.
nonisolated enum UnifiedTextDiff {
    /// Files larger than this are listed without a line diff.
    static let maximumBytes = 1_048_576

    /// A display-only diff block. `location` decides which actions the widget
    /// offers; Cowork blocks never offer Undo or Git review.
    static func reviewBlock(
        path: String,
        original: String?,
        modified: String?,
        root: String,
        location: DiffPatchLocation
    ) -> DiffPatchBlock {
        let counts = lineCounts(original: original ?? "", modified: modified ?? "")
        var block = DiffPatchBlock(
            workspaceRoot: root,
            patch: (try? patch(path: path, original: original, modified: modified ?? "")) ?? "",
            patches: nil,
            files: [DiffPatchFileChange(path: path, additions: counts.additions, deletions: counts.deletions)],
            reviewFiles: [DiffReviewFileSnapshot(path: path, originalText: original, modifiedText: modified)],
            status: .applied,
            errorMessage: nil
        )
        block.location = location
        return block
    }

    /// Added and removed line counts from a longest-common-subsequence walk
    /// over line hashes; exact for the sizes Cowork reviews.
    static func lineCounts(original: String, modified: String) -> (additions: Int, deletions: Int) {
        let old = original.isEmpty ? [] : original.components(separatedBy: "\n")
        let new = modified.isEmpty ? [] : modified.components(separatedBy: "\n")
        let difference = new.difference(from: old)
        return (difference.insertions.count, difference.removals.count)
    }

    /// Text when the data is valid UTF-8 without NUL bytes and small enough
    /// to review; `nil` for binary or oversized content.
    static func reviewableText(_ data: Data) -> String? {
        guard data.count <= maximumBytes, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func patch(path: String, original: String?, modified: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appendingPathComponent("old")
        let newURL = directory.appendingPathComponent("new")
        try (original ?? "").write(to: oldURL, atomically: true, encoding: .utf8)
        try modified.write(to: newURL, atomically: true, encoding: .utf8)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = [
            "-u", "--label", original == nil ? "/dev/null" : "a/\(path)", "--label", "b/\(path)",
            oldURL.path, newURL.path,
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // diff exits 0 for identical input and 1 when a patch was written.
        return String(decoding: data, as: UTF8.self)
    }
}
