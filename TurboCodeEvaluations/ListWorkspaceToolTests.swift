import Foundation
import Testing
@testable import TurboCode

@Suite("List workspace tool")
struct ListWorkspaceToolTests {
    @Test("Xcode containers are returned as ordinary directory entries")
    func xcodeContainersRemainListingData() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("Game.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        let tool = ListWorkspaceTool(workspaceRoot: workspace.path)

        let output = try await tool.call(arguments: ListWorkspaceArguments(path: "."))

        let entry = try #require(output.entries.first)
        #expect(entry.name == "Game.xcodeproj")
        #expect(entry.kind == "directory")
        #expect(output.totalCount == 1)
    }

    @Test("File extension filters are case-insensitive and exclude directories")
    func fileExtensionFilterSelectsOnlyMatchingFiles() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("Notes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("markdown", to: workspace.appendingPathComponent("README.md"))
        try write("text", to: workspace.appendingPathComponent("notes.TXT"))
        try write("swift", to: workspace.appendingPathComponent("main.swift"))
        let tool = ListWorkspaceTool(workspaceRoot: workspace.path)

        let output = try await tool.call(
            arguments: ListWorkspaceArguments(path: ".", fileExtension: ".TXT")
        )

        #expect(output.entries.map(\.name) == ["notes.TXT"])
        #expect(output.entries.allSatisfy { $0.kind == "file" })
        #expect(output.totalCount == 1)
        #expect(!output.isTruncated)
    }

    @Test("Filtering happens before the result limit")
    func fileExtensionFilterIsAppliedBeforeTruncation() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try write("text", to: workspace.appendingPathComponent("a.txt"))
        try write("markdown", to: workspace.appendingPathComponent("b.md"))

        let output = try WorkspaceBrowsingService(workspaceRoot: workspace.path)
            .listDirectory(at: ".", maximumEntries: 1, fileExtension: "md")

        #expect(output.entries.map(\.name) == ["b.md"])
        #expect(output.entries.first?.relativePath.hasSuffix("/b.md") == true)
        #expect(output.totalCount == 1)
        #expect(!output.isTruncated)
    }

    private func write(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url)
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TurboCode-ListWorkspaceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
