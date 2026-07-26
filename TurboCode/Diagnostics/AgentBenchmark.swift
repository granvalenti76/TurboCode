import Foundation
import FoundationModels
import FoundationModelsUtilities

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
    let kind: AgentBenchmarkKind
    let workspaceRoot: String
    let model: any LanguageModel
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let activations: SkillActivations
    let usesAgentWorkflowSkills: Bool
    let onToolStart: @Sendable (Transcript.ToolCall) async -> Void
    let onToolEnd: @Sendable (Transcript.ToolCall, Transcript.ToolOutput) async -> Void

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions {
                """
                \(kind.profileInstructions) Complete the requested change with tools,
                verify the build, and keep the final
                response brief. Never emit unified diff text and never only describe the edit.
                """
            }
            if usesAgentWorkflowSkills {
                // Read access precedes workflow selection so the benchmark also
                // exercises the production observation/action phase boundary.
                ReadFileTool(workspaceRoot: workspaceRoot)
                if kind == .swiftPackage {
                    AgentWorkflowSkills(
                        activations: activations,
                        tools: [
                            BashTool(workspaceRoot: workspaceRoot),
                            EditFileTool(workspaceRoot: workspaceRoot, reportsChanges: false)
                        ]
                    )
                } else {
                    AgentWorkflowSkills(
                        activations: activations,
                        tools: [
                            EditFileTool(workspaceRoot: workspaceRoot, reportsChanges: false),
                            XcodeProjectTool(
                                workspaceRoot: workspaceRoot,
                                executionPolicy: ExecutionPolicy(allowNetworkAccess: false),
                                enhancedOutput: false
                            )
                        ]
                    )
                }
            } else {
                ReadFileTool(workspaceRoot: workspaceRoot)
                EditFileTool(workspaceRoot: workspaceRoot, reportsChanges: false)
                if kind == .swiftPackage {
                    BashTool(workspaceRoot: workspaceRoot)
                } else {
                    XcodeProjectTool(
                        workspaceRoot: workspaceRoot,
                        executionPolicy: ExecutionPolicy(allowNetworkAccess: false),
                        enhancedOutput: false
                    )
                }
            }
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
        reasoningLevel: ContextOptions.ReasoningLevel?,
        kind: AgentBenchmarkKind = .swiftPackage
    ) async -> AgentBenchmarkResult {
        let startedAt = Date()
        let prompt = kind.prompt
        let runID = await AgentDiagnosticsRecorder.shared.startRun(
            backend: backend,
            mode: .standalone,
            profileVersion: AgentProfileVersion.value(for: backend, mode: .standalone),
            workspaceKind: kind.workspaceKind,
            promptCharacters: prompt.count,
            source: "benchmark"
        )

        let workspace: URL
        do {
            workspace = try AgentBenchmarkFixture.make(kind)
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
            kind: kind,
            workspaceRoot: workspace.path,
            model: model,
            reasoningLevel: reasoningLevel,
            activations: SkillActivations(),
            usesAgentWorkflowSkills:
                backend == .llamaServer || backend == .foundationServe,
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

            let fileURL = workspace.appendingPathComponent(kind.expectedFilePath)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let toolCalls = session.transcript.flatMap { entry -> [Transcript.ToolCall] in
                guard case .toolCalls(let calls) = entry else { return [] }
                return Array(calls)
            }
            let calledTools = Set(toolCalls.map(\.toolName))
            guard content == kind.expectedContent else {
                let renderedContent = content
                    .replacingOccurrences(of: "\n", with: "\\n")
                throw BenchmarkVerificationError(
                    detail: """
                    Benchmark verification failed: exact paragraph layout was not preserved. \
                    Calls: \(calledTools.sorted().joined(separator: ", ")). \
                    Actual: "\(renderedContent)"
                    """
                )
            }
            var requiredTools = kind.requiredToolNames
            if profile.usesAgentWorkflowSkills {
                requiredTools.insert("load_agent_workflow")
            }
            guard requiredTools.isSubset(of: calledTools) else {
                let missing = requiredTools.subtracting(calledTools).sorted()
                throw BenchmarkVerificationError(
                    detail: """
                    Benchmark verification failed: missing agent-loop calls \
                    \(missing.joined(separator: ", ")).
                    """
                )
            }
            if kind == .xcodeProject {
                let xcodeActions = toolCalls
                    .filter { $0.toolName == "xcode_project" }
                    .compactMap {
                        try? $0.arguments.value(String.self, forProperty: "action")
                    }
                guard xcodeActions.contains("inspect"), xcodeActions.contains("build") else {
                    throw BenchmarkVerificationError(
                        detail: """
                        Benchmark verification failed: Xcode actions were \
                        \(xcodeActions.joined(separator: ", ")); inspect and build are required.
                        """
                    )
                }
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
                detail: "verified \(kind.expectedFilePath) and completed the \(kind.rawValue) loop"
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
