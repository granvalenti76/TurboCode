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

    @Test("An approved external file is read through the same tool call")
    func readsApprovedExternalFile() async throws {
        let fixture = try makeExternalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let approval = ReadFileApprovalProbe()
        let tool = ReadFileTool(
            workspaceRoot: fixture.workspace.path,
            requestApproval: { request in
                await approval.approve(request)
            }
        )

        let output = try await tool.call(arguments: ReadFileArguments(
            filePath: fixture.externalFile.path,
            startLine: nil,
            endLine: nil,
            limit: nil
        ))

        #expect(approval.count == 1)
        #expect(output.contains("external content"))
    }

    @Test("A denied external read does not expose file contents")
    func rejectsDeniedExternalFile() async throws {
        let fixture = try makeExternalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tool = ReadFileTool(
            workspaceRoot: fixture.workspace.path,
            requestApproval: { _ in "Action cancelled by the user." }
        )

        let output = try await tool.call(arguments: ReadFileArguments(
            filePath: fixture.externalFile.path,
            startLine: nil,
            endLine: nil,
            limit: nil
        ))

        #expect(output == "Action cancelled by the user.")
        #expect(!output.contains("external content"))
    }

    @Test("An external symlink target cannot change during approval")
    func rejectsRetargetedExternalSymlink() async throws {
        let fixture = try makeExternalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacement = fixture.root.appendingPathComponent("replacement.txt")
        try "replacement content\n".write(to: replacement, atomically: true, encoding: .utf8)
        let link = fixture.root.appendingPathComponent("external-link.txt")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.externalFile
        )
        let approval = ReadFileApprovalProbe(beforeAction: {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
        })
        let tool = ReadFileTool(
            workspaceRoot: fixture.workspace.path,
            requestApproval: { request in
                await approval.approve(request)
            }
        )

        let output = try await tool.call(arguments: ReadFileArguments(
            filePath: link.path,
            startLine: nil,
            endLine: nil,
            limit: nil
        ))

        #expect(output.contains("external target changed"))
        #expect(!output.contains("replacement content"))
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

    private func makeExternalFixture() throws -> (
        root: URL,
        workspace: URL,
        externalFile: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-ExternalReadTests-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let externalFile = root.appendingPathComponent("external.txt")
        try "external content\n".write(to: externalFile, atomically: true, encoding: .utf8)
        return (root, workspace, externalFile)
    }
}

private final class ReadFileApprovalProbe: @unchecked Sendable {
    private(set) var count = 0
    private let beforeAction: (() -> Void)?

    init(beforeAction: (() -> Void)? = nil) {
        self.beforeAction = beforeAction
    }

    func approve(_ request: PendingToolApproval) async -> String {
        count += 1
        beforeAction?()
        return await request.action()
    }
}
