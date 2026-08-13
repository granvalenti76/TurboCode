import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Embedded terminal")
struct EmbeddedTerminalTests {
    @Test("Launch configuration uses the active workspace and inherited shell")
    func resolvesWorkspaceAndShell() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let configuration = try #require(
            EmbeddedTerminalLaunchConfiguration.resolve(
                workspacePath: workspace.path,
                environment: ["SHELL": "/bin/sh"]
            )
        )

        #expect(configuration.workingDirectory == workspace.path)
        #expect(configuration.executable == "/bin/sh")
        #expect(configuration.arguments == ["-l"])
    }

    @Test("Launch configuration rejects a missing workspace")
    func rejectsMissingWorkspace() {
        let configuration = EmbeddedTerminalLaunchConfiguration.resolve(
            workspacePath: "/tmp/TurboCode-missing-terminal-workspace",
            environment: ["SHELL": "/bin/sh"]
        )

        #expect(configuration == nil)
    }

    @Test("Workbench navigation closes an open terminal utility area")
    func navigationClosesTerminal() {
        let workbench = WorkbenchStore()
        workbench.toggleTerminal()
        #expect(workbench.terminalPresented)

        workbench.setRoute(.tools)
        #expect(!workbench.terminalPresented)
    }
}
