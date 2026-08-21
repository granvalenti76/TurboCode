import Foundation

nonisolated enum ModelToolTier: String, Sendable, Hashable {
    case none
    case onDevice
    case standard
    case enhanced
}

nonisolated enum ModelRuntimeProfile: String, Sendable, Hashable {
    case microtask
    case standalone
    case orchestrator
    case delegate
}

nonisolated enum ToolCapabilityID: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case turboCodeGuide = "turbocode_guide"
    case listWorkspace = "list_workspace"
    case swiftWorkspaceMap = "swift_workspace_map"
    case readFile = "read_file"
    case searchWorkspace = "grep"
    case fileSystem = "file_system"
    case git
    case bash
    case swiftPackageManager = "swift_package_manager"
    case xcodeProject = "xcode_project"
    case editFile = "edit_file"
    case writeOnDevice = "write_ondevice"
    case removeFile = "remove_file"
    case safariMCP = "safari_mcp"
    case loadSkill = "load_skill"
    case createSkill = "create_skill"
    case delegateTask = "delegate_task"
    case callPowerfulModel = "call_powerful_model"

    var id: String { rawValue }

    /// Most capability identifiers equal their model-facing function name.
    /// Search keeps its historical persisted ID while exposing the replacement
    /// name, so saved profiles survive without showing a stale `grep` label.
    var runtimeName: String {
        self == .searchWorkspace ? "ripgrep" : rawValue
    }
}

nonisolated enum ToolCapabilityCategory: String, CaseIterable, Sendable, Hashable {
    case product = "Product"
    case discovery = "Exploration"
    case code = "Code"
    case execution = "Execution"
    case orchestration = "Orchestration"
}

nonisolated struct ToolCapabilityDescriptor: Identifiable, Sendable, Hashable {
    let id: ToolCapabilityID
    let name: String
    let summary: String
    let category: ToolCapabilityCategory
    let systemImage: String
    let hasNativePresentation: Bool
}

nonisolated enum ToolAvailabilityRequirement: Sendable, Hashable {
    case always
    case workspace
    case skills
    case safariMCP
    case delegateModel
    case repositoryMap
    case capableWorkspace
}

nonisolated struct ToolAccessContext: Sendable, Hashable {
    let hasWorkspace: Bool
    let hasSkills: Bool
    let safariMCPEnabled: Bool
    let hasDelegateModel: Bool
    let repositoryMapDetail: RepositoryMapDetail?

    init(
        hasWorkspace: Bool,
        hasSkills: Bool,
        safariMCPEnabled: Bool = false,
        hasDelegateModel: Bool,
        repositoryMapDetail: RepositoryMapDetail?
    ) {
        self.hasWorkspace = hasWorkspace
        self.hasSkills = hasSkills
        self.safariMCPEnabled = safariMCPEnabled
        self.hasDelegateModel = hasDelegateModel
        self.repositoryMapDetail = repositoryMapDetail
    }
}

nonisolated struct ModelToolAssignment: Identifiable, Sendable, Hashable {
    let id: ToolCapabilityID
    let isRegistered: Bool
    let unavailableReason: String?
}

nonisolated struct ModelToolPlan: Sendable, Hashable {
    let profile: ModelRuntimeProfile
    let tier: ModelToolTier
    let assignments: [ModelToolAssignment]

    var registeredIDs: Set<ToolCapabilityID> {
        Set(assignments.filter(\.isRegistered).map(\.id))
    }

    func contains(_ id: ToolCapabilityID) -> Bool {
        registeredIDs.contains(id)
    }

    func assignment(for id: ToolCapabilityID) -> ModelToolAssignment? {
        assignments.first(where: { $0.id == id })
    }
}

/// Single source of truth for tool identity, presentation metadata, profile
/// membership, and runtime requirements. Session construction and the Tools UI
/// both consume this resolver.
nonisolated enum ModelToolCatalog {
    static let descriptors: [ToolCapabilityDescriptor] = [
        .init(
            id: .turboCodeGuide,
            name: "TurboCode Guide",
            summary: "Ground product answers in the official documentation.",
            category: .product,
            systemImage: "book.closed",
            hasNativePresentation: true
        ),
        .init(
            id: .listWorkspace,
            name: "Browse Directory",
            summary: "Show a structured listing for one workspace directory.",
            category: .discovery,
            systemImage: "folder",
            hasNativePresentation: true
        ),
        .init(
            id: .swiftWorkspaceMap,
            name: "Swift Workspace Map",
            summary: "Navigate Swift declarations and relationships without reading whole files.",
            category: .discovery,
            systemImage: "map",
            hasNativePresentation: false
        ),
        .init(
            id: .readFile,
            name: "Read File",
            summary: "Read focused, numbered source ranges with a revision token.",
            category: .code,
            systemImage: "doc.text.magnifyingglass",
            hasNativePresentation: false
        ),
        .init(
            id: .searchWorkspace,
            name: "Ripgrep",
            summary: "Find workspace files or search their contents with ripgrep.",
            category: .discovery,
            systemImage: "text.magnifyingglass",
            hasNativePresentation: false
        ),
        .init(
            id: .fileSystem,
            name: "File Operations",
            summary: "Inspect metadata and perform bounded filesystem operations.",
            category: .code,
            systemImage: "folder.badge.questionmark",
            hasNativePresentation: false
        ),
        .init(
            id: .git,
            name: "Git",
            summary: "Inspect and manage the workspace repository.",
            category: .execution,
            systemImage: "arrow.triangle.branch",
            hasNativePresentation: true
        ),
        .init(
            id: .bash,
            name: "Run Command",
            summary: "Run bounded non-Xcode commands and read-only inspections.",
            category: .execution,
            systemImage: "terminal",
            hasNativePresentation: false
        ),
        .init(
            id: .swiftPackageManager,
            name: "Swift Package Manager",
            summary: "Create, configure, resolve, build, test, and inspect Swift packages.",
            category: .execution,
            systemImage: "shippingbox",
            hasNativePresentation: false
        ),
        .init(
            id: .xcodeProject,
            name: "Xcode Project",
            summary: "Inspect, build, and test Xcode projects with compact diagnostics.",
            category: .execution,
            systemImage: "hammer",
            hasNativePresentation: false
        ),
        .init(
            id: .editFile,
            name: "Edit File",
            summary: "Apply revision-bound source changes with Review and Undo.",
            category: .code,
            systemImage: "pencil.and.outline",
            hasNativePresentation: true
        ),
        .init(
            id: .writeOnDevice,
            name: "Write Workspace Root",
            summary: "Create or replace one root-level text file with a minimal on-device schema.",
            category: .code,
            systemImage: "doc.badge.plus",
            hasNativePresentation: true
        ),
        .init(
            id: .removeFile,
            name: "Remove File",
            summary: "Remove one workspace file after explicit user confirmation.",
            category: .code,
            systemImage: "trash",
            hasNativePresentation: true
        ),
        .init(
            id: .safariMCP,
            name: "Safari MCP",
            summary: "Control Safari through an explicitly enabled safaridriver MCP skill.",
            category: .execution,
            systemImage: "safari",
            hasNativePresentation: false
        ),
        .init(
            id: .loadSkill,
            name: "Load Skill",
            summary: "Load a matching workspace skill on demand.",
            category: .orchestration,
            systemImage: "puzzlepiece.extension",
            hasNativePresentation: false
        ),
        .init(
            id: .createSkill,
            name: "Create Skill",
            summary: "Create a reusable Codex-compatible skill in the active workspace.",
            category: .orchestration,
            systemImage: "puzzlepiece.extension.fill",
            hasNativePresentation: true
        ),
        .init(
            id: .delegateTask,
            name: "Delegate Task",
            summary: "Send a goal to a tool-using or text-only configured worker.",
            category: .orchestration,
            systemImage: "arrow.triangle.branch",
            hasNativePresentation: false
        ),
        .init(
            id: .callPowerfulModel,
            name: "Legacy Delegation",
            summary: "Send a free-text task through the compatibility coordinator path.",
            category: .orchestration,
            systemImage: "point.3.connected.trianglepath.dotted",
            hasNativePresentation: false
        )
    ]

    static func descriptor(for id: ToolCapabilityID) -> ToolCapabilityDescriptor {
        descriptors.first(where: { $0.id == id })!
    }

    /// The worker catalog is intentionally separate from coordinator tools.
    /// Keeping this set centralized prevents persisted worker overrides from
    /// accidentally granting recursive delegation capabilities.
    static var delegateToolIDs: Set<ToolCapabilityID> {
        Set(membership(for: .delegate).map(\.0))
    }

    static func plan(
        profile: ModelRuntimeProfile,
        tier: ModelToolTier,
        context: ToolAccessContext,
        selectedIDs: Set<ToolCapabilityID>? = nil
    ) -> ModelToolPlan {
        let profileMembership = membership(for: profile)
        var memberships = selectedIDs.map { ids in
            return ToolCapabilityID.allCases
                .filter { ids.contains($0) }
                .map { ($0, requirement(for: $0)) }
        } ?? profileMembership
        // Built-in profiles always retain the product skill authoring surface.
        // A custom profile passes selectedIDs explicitly, so its list remains
        // an actual capability boundary: omitting create_skill must remove it.
        if selectedIDs == nil,
           context.hasWorkspace,
           !memberships.contains(where: { $0.0 == .createSkill }) {
            memberships.append((.createSkill, .workspace))
        }
        // Safari is a global experimental opt-in rather than a default model
        // capability. Never pass it to delegated workers, which must remain
        // bounded to workspace-scoped operations.
        if context.safariMCPEnabled,
           profile != .delegate,
           !memberships.contains(where: { $0.0 == .safariMCP }) {
            memberships.append((.safariMCP, .safariMCP))
        }
        let assignments = memberships.compactMap { id, requirement -> ModelToolAssignment? in
            if requirement == .repositoryMap,
               (tier == .onDevice || context.repositoryMapDetail == nil) {
                return nil
            }
            if requirement == .capableWorkspace, tier == .onDevice {
                return nil
            }
            return assignment(id: id, requirement: requirement, tier: tier, context: context)
        }
        return ModelToolPlan(profile: profile, tier: tier, assignments: assignments)
    }

    private static func requirement(for id: ToolCapabilityID) -> ToolAvailabilityRequirement {
        switch id {
        case .turboCodeGuide: .always
        case .listWorkspace, .readFile, .searchWorkspace, .fileSystem, .git,
             .bash, .swiftPackageManager, .editFile, .writeOnDevice, .removeFile,
             .createSkill: .workspace
        case .swiftWorkspaceMap: .repositoryMap
        case .xcodeProject: .capableWorkspace
        case .loadSkill: .skills
        case .safariMCP: .safariMCP
        case .delegateTask, .callPowerfulModel: .delegateModel
        }
    }

    private static func membership(
        for profile: ModelRuntimeProfile
    ) -> [(ToolCapabilityID, ToolAvailabilityRequirement)] {
        switch profile {
        case .microtask:
            // This is the default native on-device surface, not a competence
            // judgment. Explicit profile selections may widen it as supported
            // by the resolved tool tier and workspace context.
            return [
                .turboCodeGuide,
                .listWorkspace,
                .readFile,
                .searchWorkspace,
                .writeOnDevice,
                .createSkill
            ]
                .sorted { $0.rawValue < $1.rawValue }
                .map { ($0, requirement(for: $0)) }
        case .standalone:
            return [
                (.turboCodeGuide, .always),
                (.listWorkspace, .workspace),
                (.swiftWorkspaceMap, .repositoryMap),
                (.readFile, .workspace),
                (.searchWorkspace, .workspace),
                (.fileSystem, .workspace),
                (.git, .workspace),
                (.bash, .workspace),
                (.swiftPackageManager, .workspace),
                (.xcodeProject, .capableWorkspace),
                (.editFile, .workspace),
                (.removeFile, .workspace),
                (.loadSkill, .skills),
                (.createSkill, .workspace)
            ]
        case .orchestrator:
            return [
                (.turboCodeGuide, .always),
                (.listWorkspace, .workspace),
                (.searchWorkspace, .workspace),
                (.fileSystem, .workspace),
                (.loadSkill, .skills),
                (.createSkill, .workspace),
                (.callPowerfulModel, .delegateModel)
            ]
        case .delegate:
            return [
                (.turboCodeGuide, .always),
                (.listWorkspace, .workspace),
                (.swiftWorkspaceMap, .repositoryMap),
                (.readFile, .workspace),
                (.searchWorkspace, .workspace),
                (.fileSystem, .workspace),
                (.git, .workspace),
                (.bash, .workspace),
                (.swiftPackageManager, .workspace),
                (.xcodeProject, .capableWorkspace),
                (.editFile, .workspace),
                (.removeFile, .workspace),
                (.loadSkill, .skills),
                (.createSkill, .workspace)
            ]
        }
    }

    private static func assignment(
        id: ToolCapabilityID,
        requirement: ToolAvailabilityRequirement,
        tier: ModelToolTier,
        context: ToolAccessContext
    ) -> ModelToolAssignment {
        guard tier != .none else {
            return .init(
                id: id,
                isRegistered: false,
                unavailableReason: "Tool calling unavailable"
            )
        }
        switch requirement {
        case .always:
            return .init(id: id, isRegistered: true, unavailableReason: nil)
        case .workspace where !context.hasWorkspace:
            return .init(id: id, isRegistered: false, unavailableReason: "Choose a workspace")
        case .skills where !context.hasSkills:
            return .init(id: id, isRegistered: false, unavailableReason: "No skills installed")
        case .safariMCP where !context.safariMCPEnabled:
            return .init(
                id: id,
                isRegistered: false,
                unavailableReason: "Enable Safari MCP in Settings > Agents > Experimental"
            )
        case .delegateModel where !context.hasDelegateModel:
            return .init(id: id, isRegistered: false, unavailableReason: "Configure a delegate model")
        case .repositoryMap:
            return context.hasWorkspace
                ? .init(id: id, isRegistered: true, unavailableReason: nil)
                : .init(id: id, isRegistered: false, unavailableReason: "Choose a workspace")
        case .capableWorkspace:
            return context.hasWorkspace
                ? .init(id: id, isRegistered: true, unavailableReason: nil)
                : .init(id: id, isRegistered: false, unavailableReason: "Choose a workspace")
        default:
            return .init(id: id, isRegistered: true, unavailableReason: nil)
        }
    }
}
