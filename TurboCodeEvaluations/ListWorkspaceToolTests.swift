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
