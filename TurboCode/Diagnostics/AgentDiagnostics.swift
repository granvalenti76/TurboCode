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
    case cancelled
    case interrupted
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
    case fileUnavailable
    case invalidRange
    case unsupportedContent
    case interrupted
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
    /// Per-response token usage is optional so diagnostics recorded before
    /// macOS 27 continue to decode without a migration step.
    var inputTokenCount: Int?
    var cachedInputTokenCount: Int?
    var outputTokenCount: Int?
    /// Context occupancy is sampled after the run because accumulated usage
    /// counts the same cached prefix again on every turn.
    var contextTokenCount: Int?
    var contextSize: Int?
}

/// Boundaries measured by the 0.3.4 harness foundation. These metrics stay
/// outside the normal UI so persistence and MainActor publication costs can be
/// compared without exposing provider transport details.
nonisolated enum RuntimeBoundary: String, Codable, Sendable {
    case settlement
    case persistence
    case restore
    case mainActorPublication
}

nonisolated struct RuntimeBoundaryMetric: Codable, Sendable {
    let id: String
    let createdAt: Date
    let boundary: RuntimeBoundary
    let backend: String?
    let durationMilliseconds: Int?
    let eventCount: Int?

    init(
        id: String = UUID().uuidString,
        createdAt: Date = .now,
        boundary: RuntimeBoundary,
        backend: String? = nil,
        durationMilliseconds: Int? = nil,
        eventCount: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.boundary = boundary
        self.backend = backend
        self.durationMilliseconds = durationMilliseconds.map { max(0, $0) }
        self.eventCount = eventCount.map { max(0, $0) }
    }
}

/// A persisted on-device context boundary, shown separately from inference
/// runs so diagnostics can distinguish summarization from model failures.
nonisolated struct OnDeviceCompactionMetric: Codable, Sendable, Identifiable {
    let id: String
    let createdAt: Date
    let turnCount: Int
    let retainedCharacters: Int
}

/// A local Llama context boundary. Kept separate from the historical
/// on-device JSONL schema so existing Apple diagnostics remain compatible.
nonisolated struct LocalCompactionMetric: Codable, Sendable, Identifiable {
    let id: String
    let createdAt: Date
    let backend: String
    let turnCount: Int
    let sourceCharacters: Int
    let retainedCharacters: Int
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
            tools: [],
            inputTokenCount: nil,
            cachedInputTokenCount: nil,
            outputTokenCount: nil,
            contextTokenCount: nil,
            contextSize: nil
        )
        return id
    }

    /// Captures the latest streaming snapshot. Foundation Models reports
    /// cumulative values for the current response, so replacing rather than
    /// adding prevents intermediate snapshots from inflating the totals.
    func recordUsage(runID: String, usage: LanguageModelSession.Usage) {
        guard var run = runs[runID] else { return }
        run.inputTokenCount = usage.input.totalTokenCount
        run.cachedInputTokenCount = usage.input.cachedTokenCount
        run.outputTokenCount = usage.output.totalTokenCount
        runs[runID] = run
    }

    /// Stores current transcript occupancy independently from response usage.
    /// This is the value that can safely be compared with the context limit.
    func recordContext(runID: String, tokenCount: Int?, contextSize: Int) {
        guard var run = runs[runID] else { return }
        run.contextTokenCount = tokenCount
        run.contextSize = contextSize
        runs[runID] = run
    }

    func markFirstToken(runID: String) {
        guard var run = runs[runID], run.firstTokenMilliseconds == nil else { return }
        run.firstTokenMilliseconds = milliseconds(since: run.startedAt)
        runs[runID] = run
    }

    /// Records a provider-neutral first-token timestamp captured at the
    /// runtime boundary. The explicit timestamp avoids measuring the whole
    /// turn when an adapter forwards synchronous stream callbacks later.
    func markFirstToken(runID: String, at timestamp: Date) {
        guard var run = runs[runID], run.firstTokenMilliseconds == nil else {
            return
        }
        run.firstTokenMilliseconds = max(
            0,
            Int(timestamp.timeIntervalSince(run.startedAt) * 1_000)
        )
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

    /// Records a normalized tool call without requiring a Foundation Models
    /// ``Transcript.ToolCall``. Codex and future adapters retain their
    /// serialized arguments at the runtime boundary, while diagnostics keep
    /// the same persisted metric shape.
    func toolStarted(runID: String, call: ToolCall, backend: ModelBackend) {
        guard var run = runs[runID], !run.tools.contains(where: { $0.id == call.id }) else {
            return
        }
        run.tools.append(
            ToolRunMetric(
                id: call.id,
                toolName: call.name,
                backend: backend.rawValue,
                startedAt: call.startedAt,
                inputContentCharacters: nil,
                inputLineCount: nil,
                inputParagraphCount: nil,
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

    /// Completes a normalized runtime tool metric using the provider-neutral
    /// status and duration carried by ``ToolResult``.
    func toolFinished(
        runID: String,
        call: ToolCall,
        output: ToolResult,
        backend: ModelBackend
    ) {
        guard var run = runs[runID] else { return }
        let text = output.output
        let classified = Self.classifyToolOutput(text, toolName: call.name)
        let outcome: ToolRunOutcome
        let category: AgentFailureCategory?
        switch output.status {
        case .succeeded:
            outcome = classified.outcome
            category = classified.category
        case .failed:
            outcome = .failed
            category = classified.category ?? .toolExecution
        case .cancelled:
            outcome = .cancelled
            category = .interrupted
        }
        let fingerprint = category == nil ? nil : Self.fingerprint(text)
        let duration = output.durationMilliseconds
            ?? max(0, Int(Date().timeIntervalSince(call.startedAt) * 1_000))

        if let index = run.tools.firstIndex(where: { $0.id == call.id }) {
            run.tools[index].durationMilliseconds = duration
            run.tools[index].outputCharacters = text.count
            run.tools[index].outcome = outcome
            run.tools[index].failureCategory = category
            run.tools[index].failureFingerprint = fingerprint
        } else {
            run.tools.append(
                ToolRunMetric(
                    id: call.id,
                    toolName: call.name,
                    backend: backend.rawValue,
                    startedAt: call.startedAt,
                    inputContentCharacters: nil,
                    inputLineCount: nil,
                    inputParagraphCount: nil,
                    durationMilliseconds: duration,
                    outputCharacters: text.count,
                    outcome: outcome,
                    failureCategory: category,
                    failureFingerprint: fingerprint
                )
            )
        }
        runs[runID] = run
    }

    func finishRun(
        runID: String,
        outcome: AgentRunOutcome,
        generatedCharacters: Int,
        error: Error? = nil,
        failure: TurnFailure? = nil
    ) {
        guard var run = runs.removeValue(forKey: runID) else { return }
        let finishedAt = Date()
        run.totalMilliseconds = Int(finishedAt.timeIntervalSince(run.startedAt) * 1_000)
        run.generatedCharacters = generatedCharacters
        Self.finalizeOpenTools(in: &run, outcome: outcome, finishedAt: finishedAt)
        run.outcome = outcome == .success && run.tools.contains(where: { $0.outcome == .failed })
            ? .successWithToolFailures
            : outcome
        if let error {
            let detail = error.localizedDescription
            run.failureCategory = Self.classifyFailure(detail)
            run.failureFingerprint = Self.fingerprint(detail)
            run.suspectedTool = Self.suspectedTool(in: detail)
        } else if let failure {
            run.failureCategory = Self.classifyFailure(failure.message)
            run.failureFingerprint = Self.fingerprint(failure.message)
            run.suspectedTool = Self.suspectedTool(in: failure.message)
        }
        append(run)
    }

    nonisolated static func finalizeOpenTools(
        in run: inout AgentRunMetric,
        outcome: AgentRunOutcome,
        finishedAt: Date
    ) {
        for index in run.tools.indices where run.tools[index].outcome == nil {
            run.tools[index].durationMilliseconds = max(
                0,
                Int(finishedAt.timeIntervalSince(run.tools[index].startedAt) * 1_000)
            )
            run.tools[index].outcome = outcome == .cancelled ? .cancelled : .interrupted
            run.tools[index].failureCategory = .interrupted
        }
    }

    func failureSummary() -> String {
        let runs = Self.persistedRuns()
        guard !runs.isEmpty else {
            return "No diagnostic runs recorded yet."
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

    /// Returns persisted and currently active on-device runs for the Developer
    /// statistics window. Filtering here keeps remote-provider diagnostics out
    /// of the UI even when they share the same root conversation.
    func onDeviceRuns() -> [AgentRunMetric] {
        let persisted = Self.persistedRuns()
        let active = runs.values.filter { $0.backend == ModelBackend.foundationApple.rawValue }
        return (persisted + active)
            .filter { $0.backend == ModelBackend.foundationApple.rawValue }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Returns Llama runs for the dedicated Developer dashboard. Keeping this
    /// filter here prevents the UI from accidentally mixing provider metrics.
    func llamaRuns() -> [AgentRunMetric] {
        let persisted = Self.persistedRuns()
        let active = runs.values.filter {
            $0.backend == ModelBackend.llamaServer.rawValue
        }
        return (persisted + active)
            .filter { $0.backend == ModelBackend.llamaServer.rawValue }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func recordCompaction(turnCount: Int, retainedCharacters: Int) {
        let metric = OnDeviceCompactionMetric(
            id: UUID().uuidString,
            createdAt: .now,
            turnCount: turnCount,
            retainedCharacters: retainedCharacters
        )
        do {
            let directory = Self.diagnosticsDirectoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("compactions.jsonl")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(metric)
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
            print("[Diagnostics] Failed to persist compaction: \(error.localizedDescription)")
        }
    }

    func recordLocalCompaction(
        backend: ModelBackend,
        turnCount: Int,
        sourceCharacters: Int,
        retainedCharacters: Int
    ) {
        let metric = LocalCompactionMetric(
            id: UUID().uuidString,
            createdAt: .now,
            backend: backend.rawValue,
            turnCount: turnCount,
            sourceCharacters: sourceCharacters,
            retainedCharacters: retainedCharacters
        )
        Self.appendJSONLine(
            metric,
            filename: "local-compactions.jsonl"
        )
    }

    /// Persists one provider-neutral boundary sample for the 0.3.4 baseline.
    func recordBoundary(_ metric: RuntimeBoundaryMetric) {
        guard Self.isEnabled else { return }
        Self.appendJSONLine(metric, filename: "boundaries.jsonl")
    }

    func localCompactions() -> [LocalCompactionMetric] {
        Self.persistedLocalCompactions().sorted { $0.createdAt > $1.createdAt }
    }

    func onDeviceCompactions() -> [OnDeviceCompactionMetric] {
        Self.persistedCompactions().sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated private static func appendJSONLine<Value: Encodable>(
        _ value: Value,
        filename: String
    ) {
        do {
            let directory = diagnosticsDirectoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(filename)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(value)
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
            print("[Diagnostics] Failed to persist local compaction: \(error.localizedDescription)")
        }
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
            switch segment {
            case .text(let text):
                return text.content
            case .structure(let structure):
                return structure.content.jsonString
            default:
                return nil
            }
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
            || (lower.contains("\"errormessage\":")
                && !lower.contains("\"errormessage\":null"))
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
            || lower.contains("edit transaction rejected")
            || lower.contains("would not change")
            || lower.contains("writes files only") {
            return .invalidEdit
        }
        if lower.contains("file not found or not readable")
            || lower.contains("workspace directory does not exist") {
            return .fileUnavailable
        }
        if lower.contains("beyond the end of the file")
            || lower.contains("startline must")
            || lower.contains("endline must")
            || lower.contains("limit must be greater than 0") {
            return .invalidRange
        }
        if lower.contains("as utf-8 text")
            || lower.contains("not readable utf-8") {
            return .unsupportedContent
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
            || lower.contains("unsafe path")
            || lower.contains("filename must be one file name") {
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
            ("ripgreptool", "ripgrep"),
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

    nonisolated private static func persistedRuns() -> [AgentRunMetric] {
        let url = diagnosticsDirectoryURL.appendingPathComponent("runs.jsonl")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return contents.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(AgentRunMetric.self, from: Data(line.utf8))
        }
    }

    nonisolated private static func persistedCompactions() -> [OnDeviceCompactionMetric] {
        let url = diagnosticsDirectoryURL.appendingPathComponent("compactions.jsonl")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return contents.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(OnDeviceCompactionMetric.self, from: Data(line.utf8))
        }
    }

    nonisolated private static func persistedLocalCompactions() -> [LocalCompactionMetric] {
        let url = diagnosticsDirectoryURL.appendingPathComponent("local-compactions.jsonl")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return contents.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(LocalCompactionMetric.self, from: Data(line.utf8))
        }
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
        if mode == .orchestrator { return "orchestrator-v2" }
        switch backend {
        case .foundationServe: return "pcc-layout-guard-v6"
        case .foundationApple: return "ondevice-layout-guard-v6"
        case .llamaServer: return "llama-layout-guard-v6"
        // DeepSeek cache metrics are comparable only within one prompt prefix.
        case .premium: return "premium-deepseek-cache-v12"
        case .codex: return "codex-app-server-v1"
        }
    }
}
