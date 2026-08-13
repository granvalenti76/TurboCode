import AppKit
import SwiftTerm
import SwiftUI

/// Describes the user-owned shell launched by the embedded terminal.
/// Keeping launch policy outside the SwiftTerm view makes a future backend
/// replacement possible without changing the workbench or workspace UI.
struct EmbeddedTerminalLaunchConfiguration: Equatable, Sendable {
    let workingDirectory: String
    let executable: String
    let arguments: [String]

    static func resolve(
        workspacePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> EmbeddedTerminalLaunchConfiguration? {
        guard !workspacePath.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspacePath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        // Respect the user's configured login shell when the app inherits it,
        // while retaining the macOS default as a dependable fallback.
        let inheritedShell = environment["SHELL"]
        let executable = inheritedShell.flatMap { shell in
            fileManager.isExecutableFile(atPath: shell) ? shell : nil
        } ?? "/bin/zsh"

        return EmbeddedTerminalLaunchConfiguration(
            workingDirectory: workspacePath,
            executable: executable,
            arguments: ["-l"]
        )
    }
}

/// A compact terminal surface owned entirely by the user. It is deliberately
/// separate from model-facing tools: opening it never grants the model shell
/// access and closing it terminates the associated pseudo-terminal process.
struct EmbeddedTerminalView: NSViewRepresentable {
    let configuration: EmbeddedTerminalLaunchConfiguration

    func makeNSView(context: Context) -> ProjectTerminalView {
        ProjectTerminalView(configuration: configuration)
    }

    func updateNSView(_ nsView: ProjectTerminalView, context: Context) {
        // Workspace changes recreate this representable through its identity.
        // A live shell is never silently moved into a different directory.
    }

    static func dismantleNSView(_ nsView: ProjectTerminalView, coordinator: ()) {
        nsView.stopProcess()
    }
}

/// Owns the SwiftTerm-specific lifecycle so the rest of TurboCode only deals
/// with a workspace-aware terminal surface.
final class ProjectTerminalView: LocalProcessTerminalView {
    private let launchConfiguration: EmbeddedTerminalLaunchConfiguration
    private var hasStartedProcess = false
    private var hasConfiguredRenderer = false

    init(configuration: EmbeddedTerminalLaunchConfiguration) {
        self.launchConfiguration = configuration
        super.init(frame: .zero)

        // A 13-point monospace face remains compact while avoiding the visual
        // strain of the smaller default on high-density desktop displays.
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        configureNativeColors()
        scrollerStyle = .overlay
        linkReporting = .implicit
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }

        configureRendererIfNeeded()
        startProcessIfNeeded()
    }

    func stopProcess() {
        guard process.running else { return }
        terminate()
    }

    private func configureRendererIfNeeded() {
        guard !hasConfiguredRenderer else { return }
        hasConfiguredRenderer = true

        // SwiftTerm's Metal path reduces CPU work for rapidly updating logs.
        // Failure is intentionally non-fatal because CoreGraphics remains a
        // complete renderer and is preferable to an unavailable terminal.
        try? setUseMetal(true)
    }

    private func startProcessIfNeeded() {
        guard !hasStartedProcess else { return }
        hasStartedProcess = true

        startProcess(
            executable: launchConfiguration.executable,
            args: launchConfiguration.arguments,
            currentDirectory: launchConfiguration.workingDirectory
        )

        // Revealing the utility area expresses intent to type here, so move
        // keyboard focus once without fighting later composer focus.
        window?.makeFirstResponder(self)
    }
}

/// Presentation wrapper for the workbench's resizable bottom utility area.
/// It deliberately has no card treatment: the native split divider provides
/// the boundary, matching the visual hierarchy of Xcode's debug area.
struct EmbeddedTerminalPanel: View {
    let configuration: EmbeddedTerminalLaunchConfiguration
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)

                Text("Terminal")
                    .font(AppTypography.controlEmphasized)

                Text(URL(fileURLWithPath: configuration.workingDirectory).lastPathComponent)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close terminal")
                .accessibilityLabel("Close terminal")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            EmbeddedTerminalView(configuration: configuration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
