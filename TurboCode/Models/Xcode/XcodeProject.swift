import Foundation

nonisolated enum XcodeProjectAction: String, Sendable {
    case inspect
    case build
    case test
}

nonisolated enum XcodeContainerKind: String, Sendable, Hashable {
    case workspace
    case project

    var xcodebuildFlag: String {
        switch self {
        case .workspace: "-workspace"
        case .project: "-project"
        }
    }
}

nonisolated struct XcodeContainer: Sendable, Hashable {
    let relativePath: String
    let url: URL
    let kind: XcodeContainerKind
}

nonisolated struct XcodeProjectDescription: Sendable, Hashable {
    let container: XcodeContainer
    let schemes: [String]
    let targets: [String]
    let configurations: [String]
}

nonisolated struct XcodeCommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
    let timedOut: Bool
    let cancelled: Bool

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

nonisolated struct XcodeIssue: Sendable, Hashable {
    enum Severity: String, Sendable, Hashable {
        case error
        case warning
        case analyzerWarning = "analyzer warning"
    }

    let severity: Severity
    let message: String
    let sourcePath: String?
    let line: Int?
    let targetName: String?
}

nonisolated struct XcodeBuildReport: Sendable {
    let status: String?
    let errorCount: Int
    let warningCount: Int
    let analyzerWarningCount: Int
    let issues: [XcodeIssue]
    let duration: TimeInterval?
    let destination: String?
}

nonisolated struct XcodeTestFailure: Sendable, Hashable {
    let testName: String
    let targetName: String
    let message: String
}

nonisolated struct XcodeTestReport: Sendable {
    let result: String
    let totalCount: Int
    let passedCount: Int
    let failedCount: Int
    let skippedCount: Int
    let failures: [XcodeTestFailure]
    let duration: TimeInterval?
    let environment: String
}

/// Typed build/test outcome consumed by deterministic agent verification.
///
/// The compact summary is presentation detail; callers decide success from the
/// process fields rather than parsing rendered tool text.
nonisolated struct XcodeVerificationExecution: Sendable {
    let succeeded: Bool
    let cancelled: Bool
    let summary: String
}

nonisolated enum XcodeProjectError: LocalizedError, Sendable {
    case unsupportedAction(String)
    case noContainer
    case invalidContainer(String)
    case noScheme(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAction(let action):
            "Unsupported Xcode action '\(action)'. Use inspect, build, or test."
        case .noContainer:
            "No .xcworkspace or .xcodeproj was found in the active workspace."
        case .invalidContainer(let path):
            "The Xcode container must be a workspace-relative .xcworkspace or .xcodeproj: \(path)"
        case .noScheme(let path):
            "No shared or visible Xcode scheme was found in \(path)."
        case .launchFailed(let message):
            "Unable to run the Xcode toolchain: \(message)"
        }
    }
}
