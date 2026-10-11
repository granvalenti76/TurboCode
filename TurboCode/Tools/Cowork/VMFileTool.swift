import Foundation
import FoundationModels

@Generable
struct VMFileArguments {
    /// Operation to perform: read, write, or list.
    var action: String
    /// Guest path. Relative paths start at the session directory.
    var path: String?
    /// Full file content for write. Replaces the file and creates parent folders.
    var content: String?
    /// First line to read, starting at 1. Defaults to 1.
    var startLine: Int?
    /// Number of lines to read. Defaults to 200, at most 400.
    var lineCount: Int?
    /// Directory depth for list. Defaults to 2, at most 4.
    var depth: Int?
}

/// Reads, writes, and lists files inside the Cowork VM.
///
/// Small local models write files far more reliably through a dedicated tool
/// than through shell heredocs. Content always travels on standard input and
/// paths are single-quoted, so neither can be interpreted by the shell.
struct VMFileTool: Tool {
    typealias Arguments = VMFileArguments
    typealias Output = String

    static let maximumWriteBytes = 1_048_576
    static let defaultLineCount = 200
    static let maximumLineCount = 400
    static let maximumListEntries = 400

    let context: CoworkSessionContext

    var name: String { ToolCapabilityID.vmFile.rawValue }
    var description: String {
        """
        Read, write, or list files in the isolated Cowork VM. Action read returns \
        numbered lines (startLine, lineCount). Action write replaces a file with \
        content and creates parent folders. Action list shows a directory tree \
        (depth). Relative paths start at the session directory; /work is \
        read-only; deliverables belong in /out.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: VMFileArguments) async throws -> String {
        let path = context.guestPath(arguments.path)
        do {
            switch arguments.action.lowercased().trimmingCharacters(in: .whitespaces) {
            case "read":
                return try await read(path: path, arguments: arguments)
            case "write":
                return try await write(path: path, content: arguments.content)
            case "list":
                return try await list(path: path, depth: arguments.depth)
            default:
                return "Unknown action \"\(arguments.action)\". Use read, write, or list."
            }
        } catch let error as CoworkVMError {
            return "The file operation did not run: \(error.localizedDescription)"
        }
    }

    private func read(path: String, arguments: VMFileArguments) async throws -> String {
        let start = max(1, arguments.startLine ?? 1)
        let count = min(max(1, arguments.lineCount ?? Self.defaultLineCount), Self.maximumLineCount)
        let end = start + count - 1
        let result = try await context.run("""
            test -f \(CoworkShell.quote(path)) || { echo "Not a file: \(path)" >&2; exit 2; }
            awk -v s=\(start) -v e=\(end) 'NR>=s && NR<=e { printf "%6d  %s\\n", NR, $0 } END { print "__TOTAL_LINES__ " NR }' \(CoworkShell.quote(path))
            """)
        guard result.exitCode == 0 else { return CoworkOutputFormatter.render(result) }
        var lines = String(decoding: result.stdout, as: UTF8.self).components(separatedBy: "\n")
        let totalLine = lines.last { $0.hasPrefix("__TOTAL_LINES__ ") } ?? ""
        let total = Int(totalLine.dropFirst("__TOTAL_LINES__ ".count)) ?? 0
        lines.removeAll { $0.hasPrefix("__TOTAL_LINES__ ") || $0.isEmpty }
        let shownEnd = min(end, total)
        let header = total == 0
            ? "\(path) is empty."
            : "\(path) lines \(min(start, total))–\(shownEnd) of \(total)"
            + (shownEnd < total ? "; continue with startLine \(shownEnd + 1)." : ".")
        return ([header] + lines).joined(separator: "\n")
    }

    private func write(path: String, content: String?) async throws -> String {
        guard let content else { return "Write needs content." }
        let data = Data(content.utf8)
        guard data.count <= Self.maximumWriteBytes else {
            return "Content is \(data.count) bytes; the limit is \(Self.maximumWriteBytes). Write smaller files or generate them with vm_exec."
        }
        let result = try await context.run("""
            mkdir -p -- "$(dirname -- \(CoworkShell.quote(path)))" && cat > \(CoworkShell.quote(path))
            """, stdin: data)
        guard result.exitCode == 0 else { return CoworkOutputFormatter.render(result) }
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        return "Wrote \(data.count) bytes (\(lineCount) lines) to \(path)."
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
