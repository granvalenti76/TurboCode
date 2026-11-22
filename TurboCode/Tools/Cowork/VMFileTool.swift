import Foundation
import FoundationModels

@Generable
struct VMFileArguments {
    /// Operation to perform: read, write, replace_lines, or list.
    var action: String
    /// Guest path. Relative paths start at the session directory.
    var path: String?
    /// For write: the full file content. For replace_lines: the new lines that
    /// replace startLine...endLine; empty deletes them.
    var content: String?
    /// First line to read or replace, starting at 1. Defaults to 1.
    var startLine: Int?
    /// Number of lines to read. Defaults to 200, at most 400.
    var lineCount: Int?
    /// Directory depth for list. Defaults to 2, at most 4.
    var depth: Int?
    /// Last line to replace, inclusive. Use startLine - 1 to insert before startLine.
    var endLine: Int? = nil
    /// For replace_lines: the fingerprint shown by the latest read or edit of this file.
    var fingerprint: String? = nil
}

/// Reads, writes, edits, and lists files inside the Cowork VM.
///
/// Small local models write files far more reliably through a dedicated tool
/// than through shell heredocs. Content always travels on standard input and
/// paths are single-quoted, so neither can be interpreted by the shell.
///
/// `replace_lines` exists because without it every fix rewrote the whole
/// file: slow, prone to truncated tool calls, and a frequent cause of
/// regressions in parts that already worked. It edits the numbered lines a
/// `read` returned, and only while the file still has the fingerprint that
/// read reported, so line numbers can never point at a version the model has
/// not seen (the same idea as `apply_edits` revisions).
struct VMFileTool: Tool {
    typealias Arguments = VMFileArguments
    typealias Output = ToolCommandOutput

    static let maximumWriteBytes = 1_048_576
    static let defaultLineCount = 200
    static let maximumLineCount = 400
    static let maximumListEntries = 400
    /// Leading hex digits of the SHA-256 shown to the model: enough to detect
    /// a changed file, short enough not to cost context on every read.
    static let fingerprintLength = 12
    /// Writes that would leave a file unchanged before the turn is stopped.
    /// A small model once rewrote the same file 19 times in one turn.
    static let maximumUnchangedWrites = 3
    /// Lines of context shown around an edit so the next edit can follow
    /// without another read.
    static let editContextLines = 3

    let context: CoworkSessionContext
    /// When present, text writes publish a display-only diff receipt; the
    /// widget shows it like an edit_file change but offers no Mac actions.
    let receiptRegistry: ToolReceiptRegistry?
    /// Shared by every call of this tool instance, which lives as long as the
    /// model session, so the count spans the tool loop of a turn.
    private let unchangedWrites = UnchangedWriteCounter()

    init(context: CoworkSessionContext, receiptRegistry: ToolReceiptRegistry? = nil) {
        self.context = context
        self.receiptRegistry = receiptRegistry
    }

    var name: String { ToolCapabilityID.vmFile.rawValue }
    var description: String {
        """
        Read, write, edit, or list files in the isolated Studio VM. Action read \
        returns numbered lines (startLine, lineCount) and a fingerprint. Action \
        replace_lines replaces lines startLine through endLine with content \
        (empty content deletes; endLine = startLine - 1 inserts) and needs the \
        fingerprint from the latest read or edit; prefer it to fix existing files. \
        Action write replaces a whole file with content and creates parent \
        folders. Action list shows a directory tree (depth). Relative paths start \
        at the session directory; /work is read-only; deliverables belong in /out.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: VMFileArguments) async throws -> ToolCommandOutput {
        // One gate around the whole call: a write is a read for the receipt
        // plus the write itself, and no vm_exec may run between them.
        try await context.serialized { try await perform(arguments) }
    }

    private func perform(_ arguments: VMFileArguments) async throws -> ToolCommandOutput {
        let path = context.guestPath(arguments.path)
        do {
            switch arguments.action.lowercased().trimmingCharacters(in: .whitespaces) {
            case "read":
                return .plain(try await read(path: path, arguments: arguments))
            case "write":
                return try await write(path: path, content: arguments.content)
            case "replace_lines", "replace", "edit":
                // Models reach for "edit" by habit; it means the same thing.
                return try await replaceLines(path: path, arguments: arguments)
            case "list":
                return .plain(try await list(path: path, depth: arguments.depth))
            default:
                return .plain("Unknown action \"\(arguments.action)\". Use read, write, replace_lines, or list.")
            }
        } catch let error as CoworkVMError {
            return .plain("The file operation did not run: \(error.localizedDescription)")
        }
    }

    private func read(path: String, arguments: VMFileArguments) async throws -> String {
        let start = max(1, arguments.startLine ?? 1)
        let count = min(max(1, arguments.lineCount ?? Self.defaultLineCount), Self.maximumLineCount)
        let end = start + count - 1
        let result = try await context.run("""
            test -f \(CoworkShell.quote(path)) || { echo "Not a file: \(path)" >&2; exit 2; }
            awk -v s=\(start) -v e=\(end) 'NR>=s && NR<=e { printf "%6d  %s\\n", NR, $0 } END { print "__TOTAL_LINES__ " NR }' \(CoworkShell.quote(path))
            printf '__SHA256__ %s\\n' "$(sha256sum < \(CoworkShell.quote(path)) | cut -c1-\(Self.fingerprintLength))"
            """)
        guard result.exitCode == 0 else { return CoworkOutputFormatter.render(result) }
        var lines = String(decoding: result.stdout, as: UTF8.self).components(separatedBy: "\n")
        let totalLine = lines.last { $0.hasPrefix("__TOTAL_LINES__ ") } ?? ""
        let total = Int(totalLine.dropFirst("__TOTAL_LINES__ ".count)) ?? 0
        let digestLine = lines.last { $0.hasPrefix("__SHA256__ ") } ?? ""
        let fingerprint = String(digestLine.dropFirst("__SHA256__ ".count))
        lines.removeAll { $0.hasPrefix("__TOTAL_LINES__ ") || $0.hasPrefix("__SHA256__ ") || $0.isEmpty }
        let shownEnd = min(end, total)
        var header = total == 0
            ? "\(path) is empty."
            : "\(path) lines \(min(start, total))–\(shownEnd) of \(total)"
            + (shownEnd < total ? "; continue with startLine \(shownEnd + 1)." : ".")
        if !fingerprint.isEmpty { header += " fingerprint \(fingerprint)" }
        return ([header] + lines).joined(separator: "\n")
    }

    private func write(path: String, content: String?) async throws -> ToolCommandOutput {
        guard let content else { return .plain("Write needs content.") }
        let data = Data(content.utf8)
        guard data.count <= Self.maximumWriteBytes else {
            return .plain("Content is \(data.count) bytes; the limit is \(Self.maximumWriteBytes). Write smaller files or generate them with vm_exec.")
        }
        let previous = try await previousContent(at: path)
        if case .reviewable(let original?, _) = previous, original == content {
            return .plain(try await unchanged(path: path))
        }
        await unchangedWrites.reset(path)
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let text = "Wrote \(data.count) bytes (\(lineCount) lines) to \(path)."
        let original: String?? = if case .reviewable(let original, _) = previous { original } else { nil }
        return try await store(path: path, content: content, original: original, text: text)
    }

    /// Splices the new lines into the version the model last saw. The file is
    /// read and rewritten with the same in-VM commands as `write`, so this
    /// adds no new route between the VM and the Mac.
    private func replaceLines(path: String, arguments: VMFileArguments) async throws -> ToolCommandOutput {
        guard let start = arguments.startLine else {
            return .plain("replace_lines needs startLine and endLine from a read.")
        }
        let end = arguments.endLine ?? start
        guard let expected = arguments.fingerprint?.trimmingCharacters(in: .whitespaces).lowercased(),
              !expected.isEmpty else {
            return .plain("replace_lines needs the fingerprint shown by the latest read of \(path). Read the file again.")
        }
        guard case .reviewable(let current?, let digest) = try await previousContent(at: path) else {
            return .plain("\(path) is missing, binary, or larger than \(UnifiedTextDiff.maximumBytes) bytes. Use write for a new file, or vm_exec for large ones.")
        }
        guard digest.hasPrefix(expected), expected.count >= 6 else {
            return .plain("\(path) changed since that fingerprint, so the line numbers may be wrong. Read the file again and use its new fingerprint.")
        }
        let splice: LineSplice
        switch LineSplice.apply(to: current, startLine: start, endLine: end, content: arguments.content ?? "") {
        case .success(let result): splice = result
        case .failure(let error): return .plain(error.message)
        }
        guard splice.text != current else {
            return .plain(try await unchanged(path: path))
        }
        guard Data(splice.text.utf8).count <= Self.maximumWriteBytes else {
            return .plain("The edited file would exceed \(Self.maximumWriteBytes) bytes. Split it or generate it with vm_exec.")
        }
        await unchangedWrites.reset(path)
        let newFingerprint = String(FileDigest.sha256(Data(splice.text.utf8)).prefix(Self.fingerprintLength))
        let removed = end - start + 1
        let summary = "Replaced \(removed) line\(removed == 1 ? "" : "s") with \(splice.insertedLineCount) in \(path)"
            + " (now \(splice.lineCount) lines). fingerprint \(newFingerprint)"
        let text = ([summary] + splice.excerpt(contextLines: Self.editContextLines)).joined(separator: "\n")
        return try await store(path: path, content: splice.text, original: .some(current), text: text)
    }

    /// Counts a write that would not change the file. The first ones only
    /// nudge the model; past the limit the error ends the turn, because a
    /// model repeating an identical write is stuck and will not stop itself.
    private func unchanged(path: String) async throws -> String {
        let count = await unchangedWrites.increment(path)
        guard count < Self.maximumUnchangedWrites else {
            throw VMFileToolError.repeatedUnchangedWrites(path: path, count: count)
        }
        return "\(path) already has exactly this content; nothing was written. Do something else: run, test, or check the result."
    }

    /// Writes `content` in the VM and publishes the diff receipt.
    /// `original` is `.none` for content that could not be reviewed, and
    /// `.some(nil)` for a file that did not exist.
    private func store(path: String, content: String, original: String??, text: String) async throws -> ToolCommandOutput {
        let data = Data(content.utf8)
        let result = try await context.run("""
            mkdir -p -- "$(dirname -- \(CoworkShell.quote(path)))" && cat > \(CoworkShell.quote(path))
            """, stdin: data)
        guard result.exitCode == 0 else { return .plain(CoworkOutputFormatter.render(result)) }
        guard case .some(let original) = original,
              UnifiedTextDiff.reviewableText(data) != nil else { return .plain(text) }
        let block = UnifiedTextDiff.reviewBlock(
            path: displayPath(path),
            original: original,
            modified: content,
            root: context.sessionDirectory,
            location: .coworkVM
        )
        return await .recording(
            .diffPatch(DiffPatchReceipt(transactionID: UUID().uuidString, block: block)),
            text: text,
            in: receiptRegistry
        )
    }

    private enum PreviousContent {
        /// `nil` text means the file did not exist, so the diff is a creation.
        /// The digest is the full SHA-256 of the bytes read.
        case reviewable(String?, digest: String)
        /// Binary or oversized: the write proceeds without a diff.
        case unreviewable
    }

    /// Reads at most one byte over the review limit so oversized files are
    /// detected without transferring them.
    private func previousContent(at path: String) async throws -> PreviousContent {
        let result = try await context.run("""
            if [ -f \(CoworkShell.quote(path)) ]; then head -c \(UnifiedTextDiff.maximumBytes + 1) -- \(CoworkShell.quote(path)); else exit 3; fi
            """)
        switch result.exitCode {
        case 3: return .reviewable(nil, digest: "")
        case 0:
            return UnifiedTextDiff.reviewableText(result.stdout)
                .map { .reviewable($0, digest: FileDigest.sha256(result.stdout)) } ?? .unreviewable
        default: return .unreviewable
        }
    }

    /// Paths inside the session directory are shown relative to it, as the
    /// agent usually names them.
    private func displayPath(_ path: String) -> String {
        let prefix = context.sessionDirectory + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func list(path: String, depth: Int?) async throws -> String {
        let depth = min(max(1, depth ?? 2), 4)
        let result = try await context.run("""
            test -d \(CoworkShell.quote(path)) || { echo "Not a directory: \(path)" >&2; exit 2; }
            cd -- \(CoworkShell.quote(path)) && find . -mindepth 1 -maxdepth \(depth) \\( -name node_modules -o -name .git -o -name __pycache__ -o -name .venv \\) -prune -printf '%y %s %P (skipped contents)\\n' -o -printf '%y %s %P\\n' | sort -k3 | head -n \(Self.maximumListEntries + 1)
            """)
        guard result.exitCode == 0 else { return CoworkOutputFormatter.render(result) }
        let entries = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map { line -> String in
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count == 3 else { return String(line) }
                let name = String(parts[2])
                if name.hasSuffix(" (skipped contents)") {
                    return name.replacingOccurrences(of: " (skipped contents)", with: "/  (contents skipped)")
                }
                return parts[0] == "d" ? "\(name)/" : "\(name)  (\(parts[1]) B)"
            }
        guard !entries.isEmpty else { return "\(path) is empty." }
        let truncated = entries.count > Self.maximumListEntries
        return (["\(path):"] + entries.prefix(Self.maximumListEntries)
            + (truncated ? ["… more entries omitted; list a subdirectory."] : []))
            .joined(separator: "\n")
    }
}

/// Ends a turn whose model keeps writing content a file already has.
nonisolated enum VMFileToolError: LocalizedError {
    case repeatedUnchangedWrites(path: String, count: Int)

    var errorDescription: String? {
        switch self {
        case .repeatedUnchangedWrites(let path, let count):
            "The model wrote unchanged content to \(path) \(count) times in a row, so the turn was stopped."
        }
    }
}

/// Per-path count of consecutive writes that changed nothing.
private actor UnchangedWriteCounter {
    private var counts: [String: Int] = [:]

    func increment(_ path: String) -> Int {
        counts[path, default: 0] += 1
        return counts[path, default: 0]
    }

    func reset(_ path: String) {
        counts[path] = nil
    }
}

/// Pure line replacement with the numbering `awk NR` uses in `read`: lines
/// are separated by "\n" and a final newline does not start another line.
nonisolated struct LineSplice: Equatable {
    struct Failure: Error, Equatable {
        let message: String
    }

    /// The whole edited file.
    let text: String
    let lineCount: Int
    let insertedLineCount: Int
    /// First line of the inserted block, or of the line after a deletion.
    let firstChangedLine: Int
    fileprivate let lines: [String]

    static func apply(to original: String, startLine: Int, endLine: Int, content: String) -> Result<LineSplice, Failure> {
        let hasFinalNewline = original.hasSuffix("\n")
        var lines = original.isEmpty ? [] : original.components(separatedBy: "\n")
        if hasFinalNewline { lines.removeLast() }
        let total = lines.count
        guard startLine >= 1, startLine <= total + 1 else {
            return .failure(Failure(message: "startLine \(startLine) is outside the file, which has \(total) lines."))
        }
        guard endLine >= startLine - 1, endLine <= total else {
            return .failure(Failure(message: "endLine \(endLine) must be between \(startLine - 1) (insert) and \(total), the last line."))
        }
        var replacement = content.isEmpty ? [] : content.components(separatedBy: "\n")
        // A trailing newline in content ends its last line; it is not an
        // extra empty line.
        if content.hasSuffix("\n") { replacement.removeLast() }
        lines.replaceSubrange((startLine - 1)..<endLine, with: replacement)
        // Keep the file's final newline; a file that was empty gets one.
        let keepsFinalNewline = hasFinalNewline || original.isEmpty
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + (keepsFinalNewline ? "\n" : "")
        return .success(LineSplice(
            text: text,
            lineCount: lines.count,
            insertedLineCount: replacement.count,
            firstChangedLine: startLine,
            lines: lines
        ))
    }

    /// The changed region with a few lines around it, numbered like `read`.
    func excerpt(contextLines: Int) -> [String] {
        guard !lines.isEmpty else { return [] }
        let lastChanged = firstChangedLine + max(insertedLineCount, 1) - 1
        let from = max(1, firstChangedLine - contextLines)
        let to = min(lines.count, lastChanged + contextLines)
        guard from <= to else { return [] }
        return (from...to).map { String(format: "%6d", $0) + "  " + lines[$0 - 1] }
    }
}
