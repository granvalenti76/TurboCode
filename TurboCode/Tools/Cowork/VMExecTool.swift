import Foundation
import FoundationModels

@Generable
struct VMExecArguments {
    /// Bash command or script to run inside the Cowork VM.
    var command: String
    /// Guest directory to run in. Relative paths start at the session directory.
    var workingDirectory: String?
    /// Maximum seconds before the command is killed. Defaults to 120, at most 1800.
    var timeoutSeconds: Int?
}

/// Runs a shell command inside the Cowork VM as the unprivileged `cowork`
/// user. There is no per-command approval: the VM is the isolation boundary,
/// the Mac's folders are mounted read-only, and results reach the Mac only
/// through an approved export.
struct VMExecTool: Tool {
    typealias Arguments = VMExecArguments
    typealias Output = String

    static let defaultTimeoutSeconds = 120
    static let maximumTimeoutSeconds = 1_800

    let context: CoworkSessionContext

    var name: String { ToolCapabilityID.vmExec.rawValue }
    var description: String {
        """
        Run a bash command in the isolated Cowork Linux VM (Debian 12, Node 24, \
        Python 3.11, Chromium, rg, fd, jq, git). Commands start in this session's \
        directory. /work is the user's shared folder (read-only); put deliverables \
        in /out. Use for builds, scripts, package installs, and headless rendering.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: VMExecArguments) async throws -> String {
        let seconds = min(
            max(1, arguments.timeoutSeconds ?? Self.defaultTimeoutSeconds),
            Self.maximumTimeoutSeconds
        )
        do {
            let result = try await context.run(
                arguments.command,
                workingDirectory: arguments.workingDirectory,
                timeout: .seconds(seconds)
            )
            return CoworkOutputFormatter.render(result)
        } catch let error as CoworkVMError {
            // Expected VM states are reported to the model as text so it can
            // explain them instead of retrying blindly.
            return "The command did not run: \(error.localizedDescription)"
        }
    }
}
