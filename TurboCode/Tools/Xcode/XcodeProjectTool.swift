import Foundation
import FoundationModels

@Generable
struct XcodeProjectArguments {
    /// Operation: inspect, build, or test.
    var action: String
    /// Optional workspace-relative .xcworkspace or .xcodeproj. TurboCode auto-discovers one when omitted.
    var containerPath: String?
    /// Scheme to build or test. When omitted, TurboCode selects the scheme that best matches the container or a target.
    var scheme: String?
    /// Optional build configuration, such as Debug or Release.
    var configuration: String?
    /// Optional xcodebuild destination specifier, such as platform=macOS.
    var destination: String?
    /// Optional timeout in seconds, bounded by TurboCode execution settings.
    var timeoutSeconds: Int?
}

/// A narrow Xcode surface designed for small contexts: the service consumes
/// verbose build artifacts and returns only actionable structured diagnostics.
struct XcodeProjectTool: Tool {
    typealias Arguments = XcodeProjectArguments
    typealias Output = String

    let workspaceRoot: String
    let executionPolicy: ExecutionPolicy
    let enhancedOutput: Bool
    let taskScope: AgentTaskPathScope?

    init(
        workspaceRoot: String,
        executionPolicy: ExecutionPolicy,
        enhancedOutput: Bool,
        taskScope: AgentTaskPathScope? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.executionPolicy = executionPolicy
        self.enhancedOutput = enhancedOutput
        self.taskScope = taskScope
    }

    func restricted(to scope: AgentTaskPathScope) -> Self {
        Self(
            workspaceRoot: workspaceRoot,
            executionPolicy: executionPolicy,
            enhancedOutput: enhancedOutput,
            taskScope: scope
        )
    }

    var name: String { "xcode_project" }
    var description: String {
        """
        Inspect, build, or test the active Xcode project without consuming raw
        xcodebuild logs. Use inspect to discover containers, schemes, targets,
        and configurations. Use build after source changes, and test when the
        affected scheme has tests. Pass a destination only when the default run
        destination is unsuitable. TurboCode reuses Xcode's normal DerivedData,
        places only xcresult in private temporary storage, parses structured
        diagnostics, and returns a compact summary with source locations. Prefer
        this tool over bash for Xcode builds and tests.
        """
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: XcodeProjectArguments) async throws -> String {
        if let taskScope, !taskScope.isWorkspaceWide {
            return "Error: xcode_project requires an entire-workspace task scope because project discovery and builds are workspace-wide."
        }
        do {
            return try await XcodeProjectService(
                workspaceRoot: workspaceRoot,
                executionPolicy: executionPolicy,
                enhancedOutput: enhancedOutput
            ).response(
                action: arguments.action,
                containerPath: arguments.containerPath,
                scheme: arguments.scheme,
                configuration: arguments.configuration,
                destination: arguments.destination,
                timeoutSeconds: arguments.timeoutSeconds
            )
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
