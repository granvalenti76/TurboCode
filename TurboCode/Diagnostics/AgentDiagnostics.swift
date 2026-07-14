import CryptoKit
import Foundation
import FoundationModels

nonisolated enum AgentRunOutcome: String, Codable, Sendable {
    case success
    case successWithToolFailures
    case failed
    case cancelled
}

nonisolated enum ToolRunOutcome: String, Codable, Sendable {
    case success
    case failed
    case approvalRequired
}

nonisolated enum AgentFailureCategory: String, Codable, Sendable {
    case argumentParsing
    case staleRevision
    case invalidEdit
    case gitUnavailable
    case gitApply
    case pathDenied
    case timeout
    case commandFailed
    case modelUnavailable
    case toolExecution
    case verificationFailed
    case unknown
}

nonisolated struct ToolRunMetric: Codable, Sendable {
    let id: String
    let toolName: String
    let backend: String
    let startedAt: Date
    let inputContentCharacters: Int?
    let inputLineCount: Int?
    let inputParagraphCount: Int?
    var durationMilliseconds: Int?
    var outputCharacters: Int?
    var outcome: ToolRunOutcome?
    var failureCategory: AgentFailureCategory?
    var failureFingerprint: String?
}

nonisolated struct AgentRunMetric: Codable, Sendable {
    let id: String
    let startedAt: Date
    let backend: String
    let mode: String
    let profileVersion: String
    let workspaceKind: String
    let promptCharacters: Int
    let source: String?
    var firstTokenMilliseconds: Int?
    var totalMilliseconds: Int?
    var generatedCharacters: Int
    var outcome: AgentRunOutcome?
    var failureCategory: AgentFailureCategory?
    var failureFingerprint: String?
    var suspectedTool: String?
    var tools: [ToolRunMetric]
}

nonisolated private struct ToolFailureKey: Hashable {
    let backend: String
    let tool: String
    let category: String
}

actor AgentDiagnosticsRecorder {
    static let shared = AgentDiagnosticsRecorder()

    private var runs: [String: AgentRunMetric] = [:]

    nonisolated static var isEnabled: Bool {
#if DEBUG
        true
#else
        UserDefaults.standard.bool(forKey: "agentDiagnosticsEnabled")
#endif
    }

    func startRun(
        backend: ModelBackend,
        mode: OrchestratorMode,
        profileVersion: String,
        workspaceKind: String,
        promptCharacters: Int,
        source: String = "interactive"
    ) -> String? {
        guard Self.isEnabled else { return nil }
        let id = UUID().uuidString
        runs[id] = AgentRunMetric(
            id: id,
            startedAt: .now,
            backend: backend.rawValue,
            mode: mode.rawValue,
            profileVersion: profileVersion,
            workspaceKind: workspaceKind,
            promptCharacters: promptCharacters,
            source: source,
            firstTokenMilliseconds: nil,
            totalMilliseconds: nil,
            generatedCharacters: 0,
            outcome: nil,
            failureCategory: nil,
            failureFingerprint: nil,
            suspectedTool: nil,
            tools: []
        )
        return id
    }

    func markFirstToken(runID: String) {
        guard var run = runs[runID], run.firstTokenMilliseconds == nil else { return }
        run.firstTokenMilliseconds = milliseconds(since: run.startedAt)
        runs[runID] = run
    }

    func toolStarted(runID: String, call: Transcript.ToolCall, backend: ModelBackend) {
        guard var run = runs[runID], !run.tools.contains(where: { $0.id == call.id }) else { return }
        let content = try? call.arguments.value(String.self, forProperty: "content")
        run.tools.append(
            ToolRunMetric(
                id: call.id,
                toolName: call.toolName,
                backend: backend.rawValue,
                startedAt: .now,
                inputContentCharacters: content?.count,
                inputLineCount: content.map(Self.lineCount),
                inputParagraphCount: content.map(Self.paragraphCount),
                durationMilliseconds: nil,
                outputCharacters: nil,
                outcome: nil,
                failureCategory: nil,
                failureFingerprint: nil
            )
        )
        runs[runID] = run
    }

    func toolFinished(
        runID: String,
        call: Transcript.ToolCall,
        output: Transcript.ToolOutput,
        backend: ModelBackend
    ) {
        guard var run = runs[runID] else { return }
        let text = Self.textContent(output)
        let result = Self.classifyToolOutput(text, toolName: call.toolName)

        if let index = run.tools.firstIndex(where: { $0.id == call.id }) {
            run.tools[index].durationMilliseconds = milliseconds(since: run.tools[index].startedAt)
            run.tools[index].outputCharacters = text.count
            run.tools[index].outcome = result.outcome
            run.tools[index].failureCategory = result.category
            run.tools[index].failureFingerprint = result.category == nil ? nil : Self.fingerprint(text)
        } else {
            run.tools.append(
                ToolRunMetric(
                    id: call.id,
                    toolName: call.toolName,
                    backend: backend.rawValue,
                    startedAt: .now,
                    inputContentCharacters: nil,
                    inputLineCount: nil,
                    inputParagraphCount: nil,
                    durationMilliseconds: 0,
                    outputCharacters: text.count,
                    outcome: result.outcome,
                    failureCategory: result.category,
                    failureFingerprint: result.category == nil ? nil : Self.fingerprint(text)
                )
            )
        }
        runs[runID] = run
    }

    func finishRun(
        runID: String,
        outcome: AgentRunOutcome,
        generatedCharacters: Int,
        error: Error? = nil
    ) {
        guard var run = runs.removeValue(forKey: runID) else { return }
        run.totalMilliseconds = milliseconds(since: run.startedAt)
        run.generatedCharacters = generatedCharacters
        run.outcome = outcome == .success && run.tools.contains(where: { $0.outcome == .failed })
            ? .successWithToolFailures
            : outcome
        if let error {
            let detail = error.localizedDescription
            run.failureCategory = Self.classifyFailure(detail)
            run.failureFingerprint = Self.fingerprint(detail)
            run.suspectedTool = Self.suspectedTool(in: detail)
        }
        append(run)
    }

    func failureSummary() -> String {
        let url = Self.diagnosticsDirectoryURL.appendingPathComponent("runs.jsonl")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "No diagnostic runs recorded yet."
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let runs = contents.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(AgentRunMetric.self, from: Data(line.utf8))
        }
        var failures: [ToolFailureKey: Int] = [:]

        for run in runs {
            for tool in run.tools where tool.outcome == .failed {
                let key = ToolFailureKey(
                    backend: tool.backend,
                    tool: tool.toolName,
                    category: (tool.failureCategory ?? .unknown).rawValue
                )
                failures[key, default: 0] += 1
            }
            if run.outcome == .failed, run.tools.allSatisfy({ $0.outcome != .failed }) {
                let key = ToolFailureKey(
                    backend: run.backend,
                    tool: run.suspectedTool ?? "session",
                    category: (run.failureCategory ?? .unknown).rawValue
                )
                failures[key, default: 0] += 1
            }
        }

        guard !failures.isEmpty else {
            return "No tool failures across \(runs.count) diagnostic run(s)."
        }
        let rows = failures.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.backend < $1.key.backend
        }.map { entry in
            "\(entry.value)x | \(entry.key.backend) | \(entry.key.tool) | \(entry.key.category)"
        }
        return (["Tool failures across \(runs.count) diagnostic run(s):"] + rows)
            .joined(separator: "\n")
    }

    private func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }

    private func append(_ run: AgentRunMetric) {
        do {
            let directory = Self.diagnosticsDirectoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("runs.jsonl")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(run)
            data.append(0x0A)

            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            print("[Diagnostics] Failed to persist run: \(error.localizedDescription)")
        }
    }

    nonisolated static func textContent(_ output: Transcript.ToolOutput) -> String {
        output.segments.compactMap { segment -> String? in
            if case .text(let text) = segment { return text.content }
            return nil
        }.joined()
    }

    nonisolated static func classifyToolOutput(
        _ text: String,
        toolName: String
    ) -> (outcome: ToolRunOutcome, category: AgentFailureCategory?) {
        let lower = text.lowercased()
        if lower.contains("turbocode_approval_required") {
            return (.approvalRequired, nil)
        }

        let explicitFailure = lower.hasPrefix("error")
            || lower.hasPrefix("edit transaction rejected:")
            || lower.hasPrefix("edit transaction failed:")
            || (toolName == "bash" && !lower.contains("exit code: 0"))
        guard explicitFailure else { return (.success, nil) }
        return (.failed, classifyFailure(text))
    }

    nonisolated static func classifyFailure(_ detail: String) -> AgentFailureCategory {
        let lower = detail.lowercased()
        if lower.contains("failed to parse generated content")
            || lower.contains("parsingerror") {
            return .argumentParsing
        }
        if lower.contains("benchmark verification failed") {
            return .verificationFailed
        }
        if lower.contains("revision mismatch")
            || lower.contains("stale") {
            return .staleRevision
        }
        if lower.contains("invalid line")
            || lower.contains("overlapping operations")
            || lower.contains("unknown operation")
            || lower.contains("edit transaction rejected") {
            return .invalidEdit
        }
        if lower.contains("not a git repository")
            || lower.contains("requires a git workspace") {
            return .gitUnavailable
        }
        if lower.contains("git apply")
            || lower.contains("patch does not apply") {
            return .gitApply
        }
        if lower.contains("outside the workspace")
            || lower.contains("access denied")
            || lower.contains("unsafe path") {
            return .pathDenied
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return .timeout
        }
        if lower.contains("exit code:") && !lower.contains("exit code: 0") {
            return .commandFailed
        }
        if lower.contains("connection refused")
            || lower.contains("model unavailable")
            || lower.contains("server unavailable") {
            return .modelUnavailable
        }
        if lower.contains("invoking the tool") {
            return .toolExecution
        }
        return .unknown
    }

    nonisolated static func suspectedTool(in detail: String) -> String? {
        let lower = detail.lowercased()
        let names = [
            ("applyeditstool", "apply_edits"),
            ("editfiletool", "edit_file"),
            ("readfiletool", "read_file"),
            ("bashtool", "bash"),
            ("filesystemtool", "file_system"),
            ("greptool", "grep"),
            ("loadskilltool", "load_skill"),
            ("callpowerfulmodeltool", "call_powerful_model")
        ]
        return names.first(where: { lower.contains($0.0) })?.1
    }

    nonisolated private static func lineCount(_ content: String) -> Int {
        content.isEmpty ? 0 : content.components(separatedBy: .newlines).count
    }

    nonisolated private static func paragraphCount(_ content: String) -> Int {
        content
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    nonisolated private static var diagnosticsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".turbocode/diagnostics", isDirectory: true)
    }

    nonisolated private static func fingerprint(_ detail: String) -> String {
        let normalized = detail
            .lowercased()
            .replacingOccurrences(of: #"/[^\s'\"]+"#, with: "<path>", options: .regularExpression)
            .replacingOccurrences(of: #"\b[0-9a-f]{8,}\b"#, with: "<id>", options: .regularExpression)
        return SHA256.hash(data: Data(normalized.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum AgentProfileVersion {
    static func value(for backend: ModelBackend, mode: OrchestratorMode) -> String {
        if mode == .orchestrator { return "orchestrator-v1" }
        switch backend {
        case .foundationServe: return "pcc-layout-guard-v5"
        case .foundationApple: return "ondevice-layout-guard-v5"
        case .llamaServer: return "llama-layout-guard-v5"
        case .premium: return "premium-deepseek-tools-v8"
        }
    }
}
