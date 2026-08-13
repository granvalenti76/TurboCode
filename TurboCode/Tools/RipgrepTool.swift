import Darwin
import Foundation
import FoundationModels

@Generable
struct RipgrepArguments {
    /// Operation to perform: files or search.
    var action: String
    /// Text or regular-expression pattern. Required for search.
    var pattern: String?
    /// Workspace-relative file or directory. Defaults to the workspace root.
    var path: String?
    /// Optional ripgrep glob that includes matching files.
    var filePattern: String?
    /// Optional ripgrep glob that excludes matching files.
    var excludePattern: String?
    /// Treat pattern as literal text instead of a regular expression.
    var literal: Bool?
    /// Use case-sensitive matching. Defaults to true.
    var caseSensitive: Bool?
    /// Number of surrounding lines returned for content matches.
    var contextLines: Int?
    /// Return only paths containing a match.
    var filesOnly: Bool?
    /// Include hidden files while still respecting ignore files.
    var hidden: Bool?
    /// Optional maximum number of file paths or content matches to render.
    var maxResults: Int?
}

/// Provides ripgrep's native file discovery and content search without routing
/// model-authored values through a shell. The persisted capability remains
/// `grep` so existing dynamic profiles transparently receive the replacement.
struct RipgrepTool: Tool {
    typealias Arguments = RipgrepArguments
    typealias Output = String

    let workspaceRoot: String
    let executionPolicy: ExecutionPolicy
    let taskScope: AgentTaskPathScope?
    private let executableURL: URL?

    init(
        workspaceRoot: String,
        executionPolicy: ExecutionPolicy = ExecutionPolicy(),
        taskScope: AgentTaskPathScope? = nil,
        executableURL: URL? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.executionPolicy = executionPolicy
        self.taskScope = taskScope
        self.executableURL = executableURL
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(
            workspaceRoot: workspaceRoot,
            executionPolicy: executionPolicy,
            taskScope: scope,
            executableURL: executableURL
        )
    }

    var name: String { "ripgrep" }
    var description: String {
        """
        Find files or search their contents with ripgrep inside the active
        workspace. Use action files to discover paths and action search with a
        pattern to return matching lines. Narrow results with path, filePattern,
        or excludePattern when useful. Use read_file when matching source needs
        closer inspection.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: RipgrepArguments) async throws -> String {
        let requestedPath = arguments.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = requestedPath.flatMap { $0.isEmpty ? nil : $0 } ?? "."
        do {
            try taskScope?.validate(path)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        let rootURL: URL
        let searchURL: URL
        do {
            rootURL = try WorkspacePathResolver.resolve(".", within: workspaceRoot)
            searchURL = try WorkspacePathResolver.resolve(path, within: workspaceRoot)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        guard FileManager.default.fileExists(atPath: searchURL.path) else {
            return "Error: Path '\(path)' does not exist."
        }

        let action = arguments.action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard action == "files" || action == "search" else {
            return "Error: action must be files or search."
        }

        let pattern = arguments.pattern?.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "search", pattern?.isEmpty != false {
            return "Error: pattern is required for action search."
        }
        if let pattern, pattern.utf8.count > 4_096 {
            return "Error: pattern must be 4,096 UTF-8 bytes or fewer."
        }

        let contextLines = min(max(arguments.contextLines ?? 0, 0), 20)
        let maxResults = min(max(arguments.maxResults ?? 10_000, 1), 10_000)
        let relativePath = searchURL.path == rootURL.path
            ? "."
            : String(searchURL.path.dropFirst(rootURL.path.count + 1))
        let mode: RipgrepInvocationMode = if action == "files" {
            .files
        } else if arguments.filesOnly == true {
            .filesWithMatches(pattern: pattern!)
        } else {
            .matches(pattern: pattern!, contextLines: contextLines)
        }

        let request = RipgrepInvocation(
            mode: mode,
            relativePath: relativePath,
            filePattern: normalizedGlob(arguments.filePattern),
            excludePattern: normalizedGlob(arguments.excludePattern),
            literal: arguments.literal == true,
            caseSensitive: arguments.caseSensitive != false,
            includesHiddenFiles: arguments.hidden == true,
            timeoutSeconds: executionPolicy.defaultCommandTimeoutSeconds,
            outputCharacterLimit: executionPolicy.maximumToolOutputCharacters
        )

        let result = await RipgrepRunner(executableURL: executableURL).run(
            request,
            workspaceURL: rootURL
        )
        if result.cancelled {
            return "Error: Ripgrep search was cancelled."
        }
        if result.timedOut {
            return "Error: Ripgrep timed out after \(request.timeoutSeconds) seconds."
        }
        if result.status == 1 {
            return noResultsMessage(action: action, pattern: pattern, path: relativePath)
        }
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Error: Ripgrep failed with exit code \(result.status)."
                : "Error: Ripgrep failed with exit code \(result.status): \(detail)"
        }

        switch mode {
        case .files:
            return renderPaths(
                result.stdout,
                title: "RIPGREP FILES",
                path: relativePath,
                maxResults: maxResults,
                outputLimit: request.outputCharacterLimit,
                processOutputWasLimited: result.outputWasLimited
            )
        case .filesWithMatches(let pattern):
            return renderPaths(
                result.stdout,
                title: "RIPGREP FILES WITH MATCHES",
                path: relativePath,
                pattern: pattern,
                maxResults: maxResults,
                outputLimit: request.outputCharacterLimit,
                processOutputWasLimited: result.outputWasLimited
            )
        case .matches(let pattern, _):
            return renderMatches(
                result.stdout,
                pattern: pattern,
                path: relativePath,
                maxResults: maxResults,
                outputLimit: request.outputCharacterLimit,
                processOutputWasLimited: result.outputWasLimited
            )
        }
    }

    private func normalizedGlob(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized?.isEmpty == false else { return nil }
        return normalized
    }

    private func noResultsMessage(action: String, pattern: String?, path: String) -> String {
        if action == "files" {
            return "RIPGREP FILES\npath: \(path)\n\nNo files found."
        }
        return "RIPGREP SEARCH\npattern: \(pattern ?? "")\npath: \(path)\n\nNo matches found."
    }

    private func renderPaths(
        _ data: Data,
        title: String,
        path: String,
        pattern: String? = nil,
        maxResults: Int,
        outputLimit: Int,
        processOutputWasLimited: Bool
    ) -> String {
        let components = data.split(separator: 0, omittingEmptySubsequences: true)
        let completeComponents = data.last == 0
            ? Array(components)
            : Array(components.dropLast())
        let paths = completeComponents.compactMap { String(data: Data($0), encoding: .utf8) }
        let selected = Array(paths.prefix(maxResults))
        var header = "\(title)\n"
        if let pattern { header += "pattern: \(pattern)\n" }
        header += "path: \(path)\n"

        return boundedOutput(
            header: header,
            lines: selected,
            outputLimit: outputLimit,
            knownTruncated: processOutputWasLimited || selected.count < paths.count,
            observedResultCount: paths.count,
            resultLabel: "files"
        )
    }

    private func renderMatches(
        _ data: Data,
        pattern: String,
        path: String,
        maxResults: Int,
        outputLimit: Int,
        processOutputWasLimited: Bool
    ) -> String {
        let events = data.split(separator: 0x0A).compactMap { line -> RipgrepJSONEvent? in
            try? JSONDecoder().decode(RipgrepJSONEvent.self, from: Data(line))
        }
        var renderedLines: [String] = []
        var currentPath: String?
        var matchCount = 0
        var reachedResultLimit = false
        let observedMatchCount = events.lazy.filter { $0.type == "match" }.count

        for event in events where event.type == "match" || event.type == "context" {
            guard let eventPath = event.data.path?.text,
                  let lineNumber = event.data.lineNumber,
                  let text = event.data.lines?.text else { continue }
            if event.type == "match" {
                guard matchCount < maxResults else {
                    reachedResultLimit = true
                    break
                }
                matchCount += 1
            }
            if currentPath != eventPath {
                if currentPath != nil { renderedLines.append("") }
                renderedLines.append(eventPath)
                currentPath = eventPath
            }
            let marker = event.type == "match" ? ":" : "-"
            let sourceLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, sourceLine) in sourceLines.enumerated() where !sourceLine.isEmpty {
                let clipped = String(sourceLine.prefix(2_000))
                let suffix = sourceLine.count > clipped.count ? " …" : ""
                renderedLines.append("\(lineNumber + offset)\(marker) \(clipped)\(suffix)")
            }
        }

        let header = "RIPGREP SEARCH\npattern: \(pattern)\npath: \(path)\n"
        return boundedOutput(
            header: header,
            lines: renderedLines,
            outputLimit: outputLimit,
            knownTruncated: processOutputWasLimited || reachedResultLimit,
            observedResultCount: observedMatchCount,
            resultLabel: "matches"
        )
    }

    /// Reserves room for a truthful truncation footer and only appends complete
    /// lines, so context protection never manufactures or partially cuts a match.
    private func boundedOutput(
        header: String,
        lines: [String],
        outputLimit: Int,
        knownTruncated: Bool,
        observedResultCount: Int,
        resultLabel: String
    ) -> String {
        let footerReserve = 160
        let contentLimit = max(outputLimit - footerReserve, 1)
        var output = header + "observed: \(observedResultCount) \(resultLabel)\n\n"
        var outputWasTruncated = knownTruncated
        for line in lines {
            let addition = line + "\n"
            guard output.count + addition.count <= contentLimit else {
                outputWasTruncated = true
                break
            }
            output += addition
        }
        if outputWasTruncated {
            output += "\nOutput truncated; narrow path, filePattern, excludePattern, or pattern to continue."
        }
        return String(output.prefix(outputLimit))
    }
}

private nonisolated enum RipgrepInvocationMode: Sendable {
    case files
    case filesWithMatches(pattern: String)
    case matches(pattern: String, contextLines: Int)
}

private nonisolated struct RipgrepInvocation: Sendable {
    let mode: RipgrepInvocationMode
    let relativePath: String
    let filePattern: String?
    let excludePattern: String?
    let literal: Bool
    let caseSensitive: Bool
    let includesHiddenFiles: Bool
    let timeoutSeconds: Int
    let outputCharacterLimit: Int

    var arguments: [String] {
        var values: [String]
        switch mode {
        case .files:
            values = ["--files", "--null"]
        case .filesWithMatches:
            values = ["--files-with-matches", "--null", "--color", "never"]
        case .matches(_, let contextLines):
            values = ["--json", "--color", "never"]
            if contextLines > 0 {
                values += ["--context", String(contextLines)]
            }
        }
        if case .files = mode {
            // Content-matching flags do not apply to path discovery.
        } else {
            if literal { values.append("--fixed-strings") }
            if !caseSensitive { values.append("--ignore-case") }
        }
        if includesHiddenFiles { values.append("--hidden") }
        if let filePattern { values += ["--glob", filePattern] }
        if let excludePattern { values += ["--glob", "!\(excludePattern)"] }

        switch mode {
        case .files:
            values += ["--", relativePath]
        case .filesWithMatches(let pattern), .matches(let pattern, _):
            // `--` makes patterns and paths beginning with a dash inert values,
            // preserving direct-process execution without shell-like parsing.
            values += ["--", pattern, relativePath]
        }
        return values
    }
}

private nonisolated struct RipgrepProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: String
    let timedOut: Bool
    let cancelled: Bool
    let outputWasLimited: Bool
}

/// Runs one rg process at a time and owns cancellation, timeout, and raw output
/// containment before model-facing rendering applies the configured tool limit.
private actor RipgrepRunner {
    let executableURL: URL?

    init(executableURL: URL?) {
        self.executableURL = executableURL
    }

    func run(
        _ request: RipgrepInvocation,
        workspaceURL: URL
    ) async -> RipgrepProcessResult {
        let resolvedExecutable: URL
        do {
            resolvedExecutable = try executableURL ?? RipgrepExecutableResolver.resolve()
        } catch {
            return RipgrepProcessResult(
                status: -1,
                stdout: Data(),
                stderr: error.localizedDescription,
                timedOut: false,
                cancelled: false,
                outputWasLimited: false
            )
        }

        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Ripgrep-\(UUID().uuidString)", isDirectory: true)
        let stdoutURL = outputDirectory.appendingPathComponent("stdout")
        let stderrURL = outputDirectory.appendingPathComponent("stderr")
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        } catch {
            return RipgrepProcessResult(
                status: -1,
                stdout: Data(),
                stderr: "Could not prepare Ripgrep output: \(error.localizedDescription)",
                timedOut: false,
                cancelled: false,
                outputWasLimited: false
            )
        }
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        guard let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
              let stderrHandle = try? FileHandle(forWritingTo: stderrURL) else {
            return RipgrepProcessResult(
                status: -1,
                stdout: Data(),
                stderr: "Could not open Ripgrep output files.",
                timedOut: false,
                cancelled: false,
                outputWasLimited: false
            )
        }

        let process = Process()
        process.executableURL = resolvedExecutable
        process.arguments = request.arguments
        process.currentDirectoryURL = workspaceURL
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        let startedAt = Date()
        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            return RipgrepProcessResult(
                status: -1,
                stdout: Data(),
                stderr: "Could not launch Ripgrep: \(error.localizedDescription)",
                timedOut: false,
                cancelled: false,
                outputWasLimited: false
            )
        }

        // JSON search output is more verbose than its rendered form. This raw
        // ceiling protects disk and memory without imposing search relevance.
        let rawOutputLimit = min(max(request.outputCharacterLimit * 64, 1_000_000), 8_000_000)
        var timedOut = false
        var cancelled = false
        var outputWasLimited = false
        while process.isRunning {
            if Task.isCancelled {
                cancelled = true
                process.terminate()
                break
            }
            if Date().timeIntervalSince(startedAt) >= Double(request.timeoutSeconds) {
                timedOut = true
                process.terminate()
                break
            }
            let outputSize = fileSize(stdoutURL) + fileSize(stderrURL)
            if outputSize > rawOutputLimit {
                outputWasLimited = true
                process.terminate()
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning {
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                let killDeadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < killDeadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        try? stdoutHandle.close()
        try? stderrHandle.close()

        let status = process.isRunning
            ? -1
            : (outputWasLimited ? 0 : process.terminationStatus)
        return RipgrepProcessResult(
            status: status,
            stdout: readData(stdoutURL, limit: rawOutputLimit),
            stderr: readText(stderrURL, limit: 4_000),
            timedOut: timedOut,
            cancelled: cancelled,
            outputWasLimited: outputWasLimited
        )
    }

    private func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int ?? 0
    }

    private func readData(_ url: URL, limit: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)) ?? Data()
    }

    private func readText(_ url: URL, limit: Int) -> String {
        String(data: readData(url, limit: limit), encoding: .utf8) ?? ""
    }
}

nonisolated enum RipgrepExecutableResolver {
    static func resolve() throws -> URL {
        let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = environmentPath.split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("rg")
        }
        let commonCandidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/rg"),
            URL(fileURLWithPath: "/usr/local/bin/rg")
        ]
        let configuredCandidate = ProcessInfo.processInfo.environment["TURBOCODE_RG_PATH"]
            .map { URL(fileURLWithPath: $0) }
        // TurboCode intentionally relies on a user-installed ripgrep for now;
        // the override also keeps nonstandard development setups supported.
        let candidates = [configuredCandidate].compactMap { $0 }
            + commonCandidates
            + pathCandidates
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw RipgrepExecutableError.notFound
        }
        return executable
    }
}

private enum RipgrepExecutableError: LocalizedError {
    case notFound

    var errorDescription: String? {
        "Ripgrep executable not found. Install it with 'brew install ripgrep', then relaunch TurboCode."
    }
}

private nonisolated struct RipgrepJSONEvent: Decodable {
    let type: String
    let data: Payload

    nonisolated struct Payload: Decodable {
        let path: TextValue?
        let lines: TextValue?
        let lineNumber: Int?

        private enum CodingKeys: String, CodingKey {
            case path, lines
            case lineNumber = "line_number"
        }
    }

    nonisolated struct TextValue: Decodable {
        let text: String?
    }
}
