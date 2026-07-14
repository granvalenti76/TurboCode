import Foundation
import FoundationModels

#if DEBUG
nonisolated struct AgentBenchmarkResult: Sendable {
    let backend: String
    let succeeded: Bool
    let durationMilliseconds: Int
    let detail: String

    nonisolated var summary: String {
        let status = succeeded ? "Passed" : "Failed"
        return "\(status): \(backend) editing benchmark (\(durationMilliseconds) ms) - \(detail)"
    }
}

nonisolated struct AgentBenchmarkSuiteResult: Sendable {
    let backend: String
    let results: [AgentBenchmarkResult]

    nonisolated var summary: String {
        let passed = results.filter(\.succeeded).count
        let average = results.isEmpty
            ? 0
            : results.reduce(0) { $0 + $1.durationMilliseconds } / results.count
        return "\(backend): \(passed)/\(results.count) verified, \(average) ms average"
    }
}

nonisolated private struct BenchmarkVerificationError: LocalizedError, Sendable {
    let detail: String
    nonisolated var errorDescription: String? { detail }
}

private struct AgentBenchmarkProfile: LanguageModelSession.DynamicProfile {
    let workspaceRoot: String
    let model: any LanguageModel
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let onToolStart: @Sendable (Transcript.ToolCall) async -> Void
    let onToolEnd: @Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions {
                """
                You are running TurboCode's deterministic editing benchmark. Complete the
                requested file change with tools. Read the target range immediately before
                editing, copy its Revision exactly, perform the edit, and keep the final
                response brief. Never emit unified diff text and never only describe the edit.
                """
            }
            ReadFileTool(workspaceRoot: workspaceRoot)
            BashTool(workspaceRoot: workspaceRoot)
            EditFileTool(workspaceRoot: workspaceRoot, reportsChanges: false)
        }
        .model(model)
        .reasoningLevel(reasoningLevel)
        .onToolCall { call in await onToolStart(call) }
        .onToolOutput { call, output in await onToolEnd(call, output) }
    }
}

@MainActor
enum AgentBenchmarkRunner {
    static func runSuite(
        backend: ModelBackend,
        model: any LanguageModel,
        reasoningLevel: ContextOptions.ReasoningLevel?,
        iterations: Int = 5
    ) async -> AgentBenchmarkSuiteResult {
        var results: [AgentBenchmarkResult] = []
        for _ in 0..<max(1, iterations) {
            guard !Task.isCancelled else { break }
            results.append(
                await run(
                    backend: backend,
                    model: model,
                    reasoningLevel: reasoningLevel
                )
            )
        }
        return AgentBenchmarkSuiteResult(backend: backend.rawValue, results: results)
    }

    static func run(
        backend: ModelBackend,
        model: any LanguageModel,
        reasoningLevel: ContextOptions.ReasoningLevel?
    ) async -> AgentBenchmarkResult {
        let startedAt = Date()
        let prompt = """
        In Sample.md, replace the Placeholder line with exactly two prose paragraphs.
        The first paragraph must be "TurboCode edits quickly." and the second must be
        "Paragraph breaks stay intact." Separate them with one blank line. Use the
        editing tool and verify the file after the edit.
        """
        let runID = await AgentDiagnosticsRecorder.shared.startRun(
            backend: backend,
            mode: .standalone,
            profileVersion: AgentProfileVersion.value(for: backend, mode: .standalone),
            workspaceKind: "git",
            promptCharacters: prompt.count,
            source: "benchmark"
        )

        let workspace: URL
        do {
            workspace = try makeFixture()
        } catch {
            if let runID {
                await AgentDiagnosticsRecorder.shared.finishRun(
                    runID: runID,
                    outcome: .failed,
                    generatedCharacters: 0,
                    error: error
                )
            }
            return result(backend: backend, startedAt: startedAt, error: error)
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        let profile = AgentBenchmarkProfile(
            workspaceRoot: workspace.path,
            model: model,
            reasoningLevel: reasoningLevel,
            onToolStart: { call in
                guard let runID else { return }
                await AgentDiagnosticsRecorder.shared.toolStarted(
                    runID: runID,
                    call: call,
                    backend: backend
                )
            },
            onToolEnd: { call, output in
                guard let runID else { return }
                await AgentDiagnosticsRecorder.shared.toolFinished(
                    runID: runID,
                    call: call,
                    output: output,
                    backend: backend
                )
            }
        )
        let session = LanguageModelSession(profile: profile)
        var generatedCharacters = 0
        var didRecordFirstToken = false

        do {
            for try await snapshot in session.streamResponse(to: prompt) {
                let count = snapshot.content.count
                generatedCharacters = max(generatedCharacters, count)
                if !didRecordFirstToken, count > 0, let runID {
                    didRecordFirstToken = true
                    await AgentDiagnosticsRecorder.shared.markFirstToken(runID: runID)
                }
            }

            let fileURL = workspace.appendingPathComponent("Sample.md")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let expected = """
            # Notes

            TurboCode edits quickly.

            Paragraph breaks stay intact.
            """
            guard content == expected else {
                throw BenchmarkVerificationError(
                    detail: "Benchmark verification failed: exact paragraph layout was not preserved."
                )
            }
            if let runID {
                await AgentDiagnosticsRecorder.shared.finishRun(
                    runID: runID,
                    outcome: .success,
                    generatedCharacters: generatedCharacters
                )
            }
            return AgentBenchmarkResult(
                backend: backend.rawValue,
                succeeded: true,
                durationMilliseconds: elapsed(since: startedAt),
                detail: "verified Sample.md paragraph layout"
            )
        } catch {
            if let runID {
                await AgentDiagnosticsRecorder.shared.finishRun(
                    runID: runID,
                    outcome: .failed,
                    generatedCharacters: generatedCharacters,
                    error: error
                )
            }
            return result(backend: backend, startedAt: startedAt, error: error)
        }
    }

    private static func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCodeBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        # Notes

        Placeholder
        """.write(
            to: directory.appendingPathComponent("Sample.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["init", "--quiet"], in: directory)
        try runGit(["add", "Sample.md"], in: directory)
        try runGit(
            [
                "-c", "user.name=TurboCode Benchmark",
                "-c", "user.email=benchmark@localhost",
                "commit", "--quiet", "-m", "Initial fixture"
            ],
            in: directory
        )
        return directory
    }

    private static func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(decoding: data, as: UTF8.self)
            throw BenchmarkVerificationError(
                detail: "Could not prepare benchmark Git fixture: \(detail)"
            )
        }
    }

    private static func result(
        backend: ModelBackend,
        startedAt: Date,
        error: Error
    ) -> AgentBenchmarkResult {
        AgentBenchmarkResult(
            backend: backend.rawValue,
            succeeded: false,
            durationMilliseconds: elapsed(since: startedAt),
            detail: error.localizedDescription
        )
    }

    private static func elapsed(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }
}
#endif
