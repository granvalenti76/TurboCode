import Evaluations
import Foundation
import FoundationModels
import Testing
@testable import TurboCode

private let workspaceMetric = Metric("workspace_state")
private let toolMetric = Metric("required_tools")
private let errorMetric = Metric("tool_errors")

private struct GoldenValue: Codable, Sendable {
    let id: String
    let files: [String: String]
    let requiredTools: [String]
    let gitRepository: Bool
    let gitHeadMessage: String?
    let response: String
    let toolNames: [String]
    let toolErrors: [String]
}

private struct GoldenSample: SampleProtocol {
    let input: String
    let expected: GoldenValue?
}

private struct EvaluationProfile: LanguageModelSession.DynamicProfile {
    let workspaceRoot: String
    let scenarioID: String

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions {
                """
                You are TurboCode's Swift and SwiftUI coding agent. Work only inside the
                active workspace. Use read_file before editing existing files and copy its
                Revision exactly. Use edit_file for text changes and git for every Git
                operation, including repository initialization and commits. Complete the
                requested operation instead of merely explaining commands. Keep the final
                response brief.
                """
            }
            if scenarioID == "initialize-git" || scenarioID == "commit-change" {
                GitTool(
                    workspaceRoot: workspaceRoot,
                    policy: GitPolicy(confirmsDestructiveOperations: false),
                    executionPolicy: ExecutionPolicy(allowNetworkAccess: false)
                )
            } else {
                ReadFileTool(workspaceRoot: workspaceRoot)
                EditFileTool(workspaceRoot: workspaceRoot, reportsChanges: false)
            }
        }
        .model(SystemLanguageModel.default)
        .droppingCompletedToolCalls()
    }
}

private struct TurboCodeGoldenEvaluation: Evaluation {
    let dataset: ArrayLoader<GoldenSample>

    init(sample: GoldenSample) {
        dataset = ArrayLoader(samples: [sample])
    }

    func subject(from sample: GoldenSample) async throws -> ModelSubject<GoldenValue> {
        guard SystemLanguageModel.default.isAvailable else {
            throw SubjectInferenceError.failed(reason: "Apple on-device model is unavailable")
        }
        guard let expected = sample.expected else {
            throw SubjectInferenceError.failed(reason: "Golden sample has no expectation")
        }

        let workspace = try GoldenFixtures.makeWorkspace(for: expected.id)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let session = LanguageModelSession(
            profile: EvaluationProfile(workspaceRoot: workspace.path, scenarioID: expected.id)
        )
        let response = try await session.respond(to: sample.input).content
        let toolCalls = session.transcript.structuredTranscript.toolCalls
        let actual = GoldenValue(
            id: expected.id,
            files: GoldenFixtures.readFiles(expected.files.keys, from: workspace),
            requiredTools: [],
            gitRepository: GoldenFixtures.isGitRepository(workspace),
            gitHeadMessage: GoldenFixtures.gitHeadMessage(workspace),
            response: response,
            toolNames: toolCalls.map(\.toolName),
            toolErrors: GoldenFixtures.toolErrors(in: session.transcript)
        )
        return ModelSubject(value: actual, transcript: session.transcript.structuredTranscript)
    }

    @EvaluatorsBuilder<GoldenSample, ModelSubject<GoldenValue>>
    var evaluators: Evaluators {
        Evaluator { sample, subject in
            guard let expected = sample.expected else {
                return workspaceMetric.failing(rationale: "Missing expectation")
            }
            let matches = filesMatch(expected.files, subject.value.files)
                && expected.gitRepository == subject.value.gitRepository
                && expected.gitHeadMessage == subject.value.gitHeadMessage
            return matches
                ? workspaceMetric.passing()
                : workspaceMetric.failing(rationale: "Workspace or Git state differs from golden value")
        }
        Evaluator { sample, subject in
            let required = Set(sample.expected?.requiredTools ?? [])
            let called = Set(subject.value.toolNames)
            let missing = required.subtracting(called).sorted()
            return missing.isEmpty
                ? toolMetric.passing()
                : toolMetric.failing(rationale: "Missing tool calls: \(missing.joined(separator: ", "))")
        }
        Evaluator { _, subject in
            subject.value.toolErrors.isEmpty
                ? errorMetric.passing()
                : errorMetric.failing(rationale: subject.value.toolErrors.joined(separator: " | "))
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: workspaceMetric)
        aggregator.computeMean(of: toolMetric)
        aggregator.computeMean(of: errorMetric)
    }
}

private func filesMatch(_ expected: [String: String], _ actual: [String: String]) -> Bool {
    guard expected.keys == actual.keys else { return false }
    return expected.allSatisfy { path, expectedContent in
        guard let actualContent = actual[path] else { return false }
        return canonicalFileContent(expectedContent) == canonicalFileContent(actualContent)
    }
}

private func canonicalFileContent(_ content: String) -> Substring {
    content.hasSuffix("\n") ? content.dropLast() : content[...]
}

// These evaluations exercise the Apple on-device model and are intentionally
// opt-in: provider availability and model behavior are not deterministic
// prerequisites for the application regression gate.
@Suite(
    "TurboCode agent evaluations",
    .serialized,
    .disabled("Opt-in on-device golden evaluation; excluded from the regression gate")
)
struct TurboCodeAgentEvaluationTests {
    @Test(
        "Read a Swift package",
        .timeLimit(.minutes(2)),
        .evaluates(TurboCodeGoldenEvaluation(sample: GoldenFixtures.samples[0]), info: evaluationInfo)
    )
    func readSwiftPackage() throws { try verifyCurrentEvaluation() }

    @Test(
        "Exact prose edit",
        .timeLimit(.minutes(2)),
        .evaluates(TurboCodeGoldenEvaluation(sample: GoldenFixtures.samples[1]), info: evaluationInfo)
    )
    func exactProseEdit() throws { try verifyCurrentEvaluation() }

    @Test(
        "Create a SwiftUI view",
        .timeLimit(.minutes(2)),
        .evaluates(TurboCodeGoldenEvaluation(sample: GoldenFixtures.samples[2]), info: evaluationInfo)
    )
    func createSwiftUIView() throws { try verifyCurrentEvaluation() }

    @Test(
        "Initialize Git",
        .timeLimit(.minutes(2)),
        .evaluates(TurboCodeGoldenEvaluation(sample: GoldenFixtures.samples[3]), info: evaluationInfo)
    )
    func initializeGit() throws { try verifyCurrentEvaluation() }

    @Test(
        "Commit a change",
        .timeLimit(.minutes(2)),
        .evaluates(TurboCodeGoldenEvaluation(sample: GoldenFixtures.samples[4]), info: evaluationInfo)
    )
    func commitChange() throws { try verifyCurrentEvaluation() }
}

private let evaluationInfo = ["backend": "apple-on-device"]

private func verifyCurrentEvaluation() throws {
    let result = EvaluationContext.current.result
    let reportDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("EvaluationReports", isDirectory: true)
    try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
    try result.saveJSON(to: reportDirectory, includeReportMetadata: true)

    #expect(result.aggregateValue(.mean(of: workspaceMetric)) == 1)
    #expect(result.aggregateValue(.mean(of: toolMetric)) == 1)
    #expect(result.aggregateValue(.mean(of: errorMetric)) == 1)
}

private enum GoldenFixtures {
    static let notes = """
    # Notes

    Placeholder
    """

    static let editedNotes = """
    # Notes

    TurboCode edits quickly.

    Paragraph breaks stay intact.
    """

    static let contentView = """
    import SwiftUI

    struct ContentView: View {
        var body: some View {
            Text("Hello, TurboCode")
        }
    }
    """

    static let samples: [GoldenSample] = [
        sample(
            id: "read-swift-package",
            prompt: "Read Package.swift and tell me the package name. Use the file tool.",
            files: ["Package.swift": "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"GoldenApp\")"],
            tools: ["read_file"]
        ),
        sample(
            id: "exact-prose-edit",
            prompt: """
            In Sample.md preserve lines 1 and 2 exactly. Replace only line 3, which contains
            Placeholder, with exactly two paragraphs: first
            "TurboCode edits quickly." then a blank line then "Paragraph breaks stay intact.".
            Use replace_lines with startLine 3 and endLine 3, then verify the result.
            """,
            files: ["Sample.md": editedNotes],
            tools: ["read_file", "edit_file"]
        ),
        sample(
            id: "create-swiftui-view",
            prompt: """
            Create ContentView.swift with exactly this content, including `var body`:
            import SwiftUI

            struct ContentView: View {
                var body: some View {
                    Text("Hello, TurboCode")
                }
            }
            """,
            files: ["ContentView.swift": contentView],
            tools: ["edit_file"]
        ),
        sample(
            id: "initialize-git",
            prompt: "Initialize this workspace as a Git repository with main as its initial branch.",
            files: [:],
            tools: ["git"],
            gitRepository: true
        ),
        sample(
            id: "commit-change",
            prompt: "Use the git tool to stageAll, then call it again to commit with the exact message Add settings view. Do not stop after staging.",
            files: ["SettingsView.swift": "import SwiftUI\n"],
            tools: ["git"],
            gitRepository: true,
            gitHeadMessage: "Add settings view"
        )
    ]

    private static func sample(
        id: String,
        prompt: String,
        files: [String: String],
        tools: [String],
        gitRepository: Bool = false,
        gitHeadMessage: String? = nil
    ) -> GoldenSample {
        GoldenSample(
            input: prompt,
            expected: GoldenValue(
                id: id,
                files: files,
                requiredTools: tools,
                gitRepository: gitRepository,
                gitHeadMessage: gitHeadMessage,
                response: "",
                toolNames: [],
                toolErrors: []
            )
        )
    }

    static func makeWorkspace(for id: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCodeEvaluation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        switch id {
        case "read-swift-package":
            try samples[0].expected?.files["Package.swift"]?.write(
                to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8
            )
        case "exact-prose-edit":
            try notes.write(to: root.appendingPathComponent("Sample.md"), atomically: true, encoding: .utf8)
        case "commit-change":
            try runGit(["init", "--quiet", "--initial-branch", "main"], in: root)
            try runGit(["config", "user.name", "TurboCode Evaluations"], in: root)
            try runGit(["config", "user.email", "evaluations@localhost"], in: root)
            try "import SwiftUI\n".write(
                to: root.appendingPathComponent("SettingsView.swift"), atomically: true, encoding: .utf8
            )
        default:
            break
        }
        return root
    }

    static func readFiles(_ paths: Dictionary<String, String>.Keys, from root: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: paths.map { path in
            let value = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? "<missing>"
            return (path, value)
        })
    }

    static func isGitRepository(_ root: URL) -> Bool {
        (try? gitOutput(["rev-parse", "--is-inside-work-tree"], in: root)) == "true"
    }

    static func gitHeadMessage(_ root: URL) -> String? {
        try? gitOutput(["log", "-1", "--pretty=%s"], in: root)
    }

    static func toolErrors(in transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            guard case .toolOutput(let output) = entry else { return nil }
            let text = output.segments.map(\.description).joined(separator: " ")
            let isTerminalFailure = text.localizedCaseInsensitiveContains("Edit transaction failed:")
                || text.localizedCaseInsensitiveContains("Git exit code: 1")
                || text.localizedCaseInsensitiveContains("Git exit code: 128")
            return isTerminalFailure ? text : nil
        }
    }

    private static func runGit(_ arguments: [String], in root: URL) throws {
        _ = try gitOutput(arguments, in: root)
    }

    private static func gitOutput(_ arguments: [String], in root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
