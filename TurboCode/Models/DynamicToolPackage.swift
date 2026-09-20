import Foundation

/// A small, stable capability bundle selected by the experimental Dynamic
/// router. The bundle is intersected with the active profile before tools are
/// materialized, so routing never widens a user's explicit capability boundary.
nonisolated enum DynamicToolPackage: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case conversation
    case exploration
    case coding
    case git
    case build
    case implementation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .exploration: "Explore"
        case .coding: "Code"
        case .git: "Git"
        case .build: "Build"
        case .implementation: "Implement"
        }
    }

    var summary: String {
        switch self {
        case .conversation:
            "Answer with basic workspace reading and editing available."
        case .exploration:
            "Inspect files, search the workspace, and read repository structure."
        case .coding:
            "Inspect and edit workspace files with the profile's safeguards."
        case .git:
            "Inspect the repository and its current Git state."
        case .build:
            "Inspect, build, test, and diagnose the workspace."
        case .implementation:
            "Inspect, edit, run checks, and work with Git."
        }
    }

    /// One compact semantic definition per category lets the multilingual
    /// encoder generalize without accumulating request-specific examples.
    var classifierDescription: String {
        switch self {
        case .conversation:
            "Conversation, explanations and text rewriting with basic workspace access."
        case .exploration:
            "Read and search workspace files to understand the project."
        case .coding:
            "Modify workspace code or documents."
        case .git:
            "Inspect and manage Git changes, branches and commits."
        case .build:
            "Build the project, run existing tests and inspect compiler diagnostics."
        case .implementation:
            "Modify project files and then verify the changes with builds or tests."
        }
    }

    var toolIDs: Set<ToolCapabilityID> {
        switch self {
        case .conversation:
            [.listWorkspace, .readFile, .editFile]
        case .exploration:
            [.listWorkspace, .fileSystem, .readFile, .searchWorkspace]
        case .coding:
            [.listWorkspace, .swiftWorkspaceMap, .readFile, .searchWorkspace, .editFile, .fileSystem, .loadSkill]
        case .git:
            [.listWorkspace, .readFile, .searchWorkspace, .git]
        case .build:
            [.listWorkspace, .readFile, .searchWorkspace, .swiftWorkspaceMap, .xcodeProject, .swiftPackageManager, .bash]
        case .implementation:
            [.listWorkspace, .swiftWorkspaceMap, .readFile, .searchWorkspace, .fileSystem, .git, .bash, .swiftPackageManager, .xcodeProject, .editFile, .loadSkill]
        }
    }
}

/// Transient UI phases for the experimental Dynamic routing receipt. These
/// phases describe observable application work; they are not extra waits in
/// the provider path and must remain safe to skip when routing is immediate.
nonisolated enum DynamicRoutingPhase: String, Sendable, Equatable {
    case idle
    case analyzing
    case selecting
    case assembling
    case ready

    var title: String {
        switch self {
        case .idle: "Waiting"
        case .analyzing: "Analyzing prompt"
        case .selecting: "Matching intent"
        case .assembling: "Assembling tool chain"
        case .ready: "Ready"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "The next request will be routed before it reaches the model."
        case .analyzing:
            "AnchorSignal is comparing the request with the bounded tool packages."
        case .selecting:
            "The best-fit capability package has been selected."
        case .assembling:
            "The selected tools are being inserted into the session boundary."
        case .ready:
            "The session is ready with the tools selected for this request."
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle.dotted"
        case .analyzing: "waveform"
        case .selecting: "scope"
        case .assembling: "shippingbox"
        case .ready: "checkmark.circle.fill"
        }
    }
}

nonisolated struct DynamicRoutingDecision: Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case model
        case fallback
    }

    /// Nil means routing failed and the configured profile supplies its defaults.
    let package: DynamicToolPackage?
    let toolIDs: Set<ToolCapabilityID>
    let topScore: Double
    let margin: Double
    let source: Source
    let latencyMilliseconds: Double
    /// A fallback must be visible: it is not evidence that CoreAI ran.
    var fallbackReason: String? = nil

    var title: String { package?.title ?? "Profile defaults" }
    var summary: String {
        package?.summary ?? "Using the configured profile’s default tools."
    }
}

/// Resolves the candidate catalog and keeps the Dynamic feature independent
/// from the closed model-facing tool catalog implementation.
nonisolated enum DynamicToolPackageResolver {
    static func candidates(allowedToolIDs: Set<ToolCapabilityID>, prompt _: String = "") -> [DynamicToolPackage] {
        DynamicToolPackage.allCases.filter { package in
            // Eligibility depends only on profile permissions, never on words
            // in the prompt. The encoder ranks every eligible category.
            package == .conversation || package.toolIDs.isSubset(of: allowedToolIDs)
        }
    }

    static func effectiveToolIDs(
        for package: DynamicToolPackage,
        allowedToolIDs: Set<ToolCapabilityID>
    ) -> Set<ToolCapabilityID> {
        package.toolIDs.intersection(allowedToolIDs)
    }
}
