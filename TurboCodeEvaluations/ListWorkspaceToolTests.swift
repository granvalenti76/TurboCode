import Foundation
import Testing
@testable import TurboCode

@Suite("List workspace tool")
struct ListWorkspaceToolTests {
    @Test("Llama receives Xcode analysis guidance after project discovery")
    func llamaReceivesXcodeAnalysisGuidance() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("Game.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        let tool = ListWorkspaceTool(
            workspaceRoot: workspace.path,
            suggestsXcodeAnalysisTools: true
        )

        let output = try await tool.call(arguments: ListWorkspaceArguments(path: "."))

        let guidance = try #require(output.modelGuidance)
        #expect(guidance.contains("xcode-agent-loop"))
        #expect(guidance.contains("load_agent_workflow"))
        #expect(guidance.contains("xcode_project"))
        #expect(guidance.contains("without asking for confirmation"))
    }

    @Test("Non-Llama profiles keep Xcode listings free of model guidance")
    func otherProfilesDoNotReceiveXcodeAnalysisGuidance() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("Game.xcworkspace", isDirectory: true),
            withIntermediateDirectories: true
        )
        let tool = ListWorkspaceTool(workspaceRoot: workspace.path)

        let output = try await tool.call(arguments: ListWorkspaceArguments(path: "."))

        #expect(output.modelGuidance == nil)
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
