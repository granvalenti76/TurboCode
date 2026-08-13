import Foundation
import Testing
@testable import TurboCode

@Suite("Read file tool")
struct ReadFileToolTests {
    @Test("A precise range returns numbered lines and the full-file revision")
    func readsPreciseInclusiveRange() async throws {
        let fixture = try makeFixture(content: "one\ntwo\nthree\nfour\n")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let output = try await ReadFileTool(workspaceRoot: fixture.root.path)
            .call(arguments: ReadFileArguments(
                filePath: "Example.txt",
                startLine: 2,
                endLine: 3,
                limit: nil
            ))

        #expect(output.contains("File: Example.txt"))
        #expect(output.contains("Revision: \(FileRevision.hash(fixture.content))"))
        #expect(output.contains("Lines: 2-3 of 4"))
        #expect(output.contains("2 | two"))
        #expect(output.contains("3 | three"))
        #expect(!output.contains("1 | one"))
    }

    @Test("Large reads stop on a line boundary and expose the next range")
    func boundedOutputProvidesContinuation() async throws {
        let content = (1...100)
            .map { "line \($0) " + String(repeating: "x", count: 52) }
            .joined(separator: "\n")
        let fixture = try makeFixture(content: content)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let policy = ExecutionPolicy(maximumToolOutputCharacters: 1_000)

        let output = try await ReadFileTool(
            workspaceRoot: fixture.root.path,
            executionPolicy: policy
        ).call(arguments: ReadFileArguments(
            filePath: "Example.txt",
            startLine: nil,
            endLine: nil,
            limit: nil
        ))

        #expect(output.count <= 1_000)
        #expect(output.contains("Approximate tokens: ~"))
        #expect(output.contains("Output limited to 1000 characters."))
        #expect(output.contains("Continue with startLine"))
        #expect(!output.contains(fixture.root.path))
    }

    @Test("A single oversized source line is visibly clipped")
    func clipsOneOversizedLineWithoutHidingTheCondition() async throws {
        let fixture = try makeFixture(content: String(repeating: "a", count: 4_000))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let output = try await ReadFileTool(
            workspaceRoot: fixture.root.path,
            executionPolicy: ExecutionPolicy(maximumToolOutputCharacters: 1_000)
        ).call(arguments: ReadFileArguments(
            filePath: "Example.txt",
            startLine: 1,
            endLine: 1,
            limit: nil
        ))

        #expect(output.count <= 1_000)
        #expect(output.contains("[line clipped]"))
        #expect(output.contains("Line 1 exceeded the output ceiling"))
    }

    private func makeFixture(content: String) throws -> (
        root: URL,
        content: String
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-ReadFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try content.write(
            to: root.appendingPathComponent("Example.txt"),
            atomically: true,
            encoding: .utf8
        )
        return (root, content)
    }
}
