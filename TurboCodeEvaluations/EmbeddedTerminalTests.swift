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
                isEnabled: true,
                workspacePath: workspace.path,
                environment: ["SHELL": "/bin/sh"]
            )
        )

        #expect(configuration.workingDirectory == workspace.path)
        #expect(configuration.executable == "/bin/sh")
        #expect(configuration.arguments == ["-l"])
    }

    @Test("A terminal turned off in Settings launches no shell, even for a valid workspace")
    func disabledTerminalLaunchesNothing() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-Terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        #expect(EmbeddedTerminalLaunchConfiguration.resolve(
            isEnabled: false,
            workspacePath: workspace.path,
            environment: ["SHELL": "/bin/sh"]
        ) == nil)
    }

    @Test("The project terminal is off until the user turns it on")
    @MainActor
    func projectTerminalIsOffByDefault() {
        #expect(!SettingsStore().projectTerminalEnabled)
        #expect(SettingsSection.general.matches(searchQuery: "terminal"))
    }

    @Test("Launch configuration rejects a missing workspace")
    func rejectsMissingWorkspace() {
        let configuration = EmbeddedTerminalLaunchConfiguration.resolve(
            isEnabled: true,
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

        workbench.setRoute(.connectors)
        #expect(!workbench.terminalPresented)
    }
}
