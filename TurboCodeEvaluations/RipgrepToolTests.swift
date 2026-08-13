import Foundation
import Testing
@testable import TurboCode

@Suite("Ripgrep tool")
struct RipgrepToolTests {
    @Test("File discovery and content search share the replacement tool")
    func filesAndSearchActionsReturnWorkspaceRelativeEvidence() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let sources = workspace.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "let sessionStore = SessionStore()\n".write(
            to: sources.appendingPathComponent("App.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored SessionStore\n".write(
            to: sources.appendingPathComponent("Generated.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = try makeTool(workspaceRoot: workspace.path)

        let files = try await tool.call(arguments: arguments(
            action: "files",
            filePattern: "*.swift"
        ))
        let matches = try await tool.call(arguments: arguments(
            action: "search",
            pattern: #"Session(Store|Cache)"#,
            filePattern: "*.swift"
        ))

        #expect(tool.name == "ripgrep")
        #expect(files.contains("Sources/App.swift"))
        #expect(!files.contains("Generated.txt"))
        #expect(matches.contains("Sources/App.swift"))
        #expect(matches.contains("1: let sessionStore = SessionStore()"))
        #expect(!matches.contains(workspace.path))
    }

    @Test("Literal patterns are passed directly without shell interpretation")
    func literalPatternDoesNotExecuteShellSyntax() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let marker = workspace.appendingPathComponent("should-not-exist")
        let source = workspace.appendingPathComponent("Input.txt")
        try "value = $(touch should-not-exist); | still text\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )
        let tool = try makeTool(workspaceRoot: workspace.path)

        let output = try await tool.call(arguments: arguments(
            action: "search",
            pattern: "$(touch should-not-exist); |",
            literal: true
        ))

        #expect(output.contains("Input.txt"))
        #expect(output.contains("$(touch should-not-exist); |"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Ignore files and explicit filters remain under ripgrep control")
    func respectsIgnoreFilesAndExplicitExclusions() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try "Ignored/**\n".write(
            to: workspace.appendingPathComponent(".ignore"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("Ignored", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("Visible", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "needle\n".write(
            to: workspace.appendingPathComponent("Ignored/Hidden.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "needle\n".write(
            to: workspace.appendingPathComponent("Visible/Keep.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "needle\n".write(
            to: workspace.appendingPathComponent("Visible/Skip.swift"),
            atomically: true,
            encoding: .utf8
        )
        let tool = try makeTool(workspaceRoot: workspace.path)

        let output = try await tool.call(arguments: arguments(
            action: "search",
            pattern: "needle",
            excludePattern: "*Skip.swift"
        ))

        #expect(output.contains("Visible/Keep.swift"))
        #expect(!output.contains("Ignored/Hidden.swift"))
        #expect(!output.contains("Visible/Skip.swift"))
    }

    @Test("Rendered output obeys the configured infrastructure ceiling")
    func outputUsesConfiguredMaximumWithoutRankingResults() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let content = (1...300).map { "needle line \($0) " + String(repeating: "x", count: 40) }
            .joined(separator: "\n")
        try content.write(
            to: workspace.appendingPathComponent("Large.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tool = try makeTool(
            workspaceRoot: workspace.path,
            executionPolicy: ExecutionPolicy(maximumToolOutputCharacters: 1_000)
        )

        let output = try await tool.call(arguments: arguments(
            action: "search",
            pattern: "needle"
        ))

        #expect(output.count <= 1_000)
        #expect(output.contains("Output truncated"))
        #expect(output.contains("1: needle line 1"))
    }

    private func arguments(
        action: String,
        pattern: String? = nil,
        filePattern: String? = nil,
        excludePattern: String? = nil,
        literal: Bool? = nil
    ) -> RipgrepArguments {
        RipgrepArguments(
            action: action,
            pattern: pattern,
            path: ".",
            filePattern: filePattern,
            excludePattern: excludePattern,
            literal: literal,
            caseSensitive: nil,
            contextLines: nil,
            filesOnly: nil,
            hidden: nil,
            maxResults: nil
        )
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-RipgrepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTool(
        workspaceRoot: String,
        executionPolicy: ExecutionPolicy = ExecutionPolicy()
    ) throws -> RipgrepTool {
        // Xcode test hosts intentionally receive a sparse PATH. Prefer the
        // production resolver, then use Codex's executable only as a local
        // test fixture; TurboCode itself intentionally does not bundle rg.
        let fixtureURL = URL(
            fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/rg"
        )
        let executable: URL
        if let resolved = try? RipgrepExecutableResolver.resolve() {
            executable = resolved
        } else {
            try #require(FileManager.default.isExecutableFile(atPath: fixtureURL.path))
            executable = fixtureURL
        }
        return RipgrepTool(
            workspaceRoot: workspaceRoot,
            executionPolicy: executionPolicy,
            executableURL: executable
        )
    }
}
