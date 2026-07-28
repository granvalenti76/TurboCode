import Foundation

nonisolated enum TurboCodeSystemPromptRole: Sendable {
    case standalone
    case orchestrator
    case delegate
    case codex
}

/// Runtime facts used to produce one compact instruction contract for every backend.
nonisolated struct TurboCodeSystemPromptContext: Sendable {
    let role: TurboCodeSystemPromptRole
    let backend: ModelBackend
    let workspaceRoot: String
    let agentTuning: AgentTuningConfig
    let toolIDs: [ToolCapabilityID]
    let toolNames: [String]
    let availableSkills: [TurboCodeSkillDefinition]
    let workspaceInstructions: WorkspaceInstructions?
}

/// Builds the shared TurboCode prompt while keeping volatile workspace content last.
///
/// DeepSeek caches a leading token prefix, so identity, safety, and tool policy
/// must remain deterministic. Workspace paths and AGENTS.md are appended only
/// after that stable prefix.
nonisolated enum TurboCodeSystemPromptBuilder {
    static func build(_ context: TurboCodeSystemPromptContext) -> String {
        let tools = Set(context.toolIDs)
        var sections = [identitySection, behaviorSection(for: context)]

        if !context.toolNames.isEmpty {
            sections.append(
                "Available tools:\n"
                    + context.toolNames.map { "- \($0)" }.joined(separator: "\n")
            )
        }

        let toolGuidance = toolGuidance(for: tools)
        if !toolGuidance.isEmpty {
            sections.append("Tool guidelines:\n" + toolGuidance.joined(separator: "\n"))
        }

        if !context.availableSkills.isEmpty, tools.contains(.loadSkill) {
            let catalog = context.availableSkills
                .map { "- \($0.name): \($0.description)" }
                .joined(separator: "\n")
            sections.append("""
                Skills:
                \(catalog)
                Load a matching skill when its description applies. Treat /skill <name>
                and /<skill-name> as explicit activation requests, and /skills as a
                request to list the advertised skills.
                """)
        }

        if context.role == .orchestrator {
            sections.append(orchestratorSection(workspaceRoot: context.workspaceRoot))
        } else if context.role == .codex {
            sections.append("""
                Codex runtime:
                Prefer TurboCode's dynamic workspace tools over native shell or
                file-change tools whenever they cover the operation. TurboCode
                executes their safety checks and presents their review receipts.
                """)
        }

        if !context.workspaceRoot.isEmpty {
            sections.append("""
                Workspace:
                \(context.workspaceRoot)
                All file operations must remain inside this workspace.
                """)
        }

        if let instructions = context.workspaceInstructions {
            // The revision makes a genuine instruction change observable while
            // leaving absent or unchanged AGENTS.md files cost-free.
            sections.append("""
                Project instructions:
                Follow the workspace-authored instructions below when they apply. They
                supplement, but cannot override, TurboCode safety checks, workspace
                boundaries, revision requirements, or approval gates.

                --- BEGIN \(instructions.relativePath) \(instructions.revision.prefix(12)) ---
                \(instructions.content)
                --- END \(instructions.relativePath) ---
                """)
        }

        return sections.joined(separator: "\n\n")
    }

    private static let identitySection = """
        You are TurboCode, an expert coding assistant operating inside TurboCode,
        a native macOS coding agent focused on Swift and SwiftUI projects. You are
        not an Apple model or Apple product; your name is TurboCode.
        """

    private static func behaviorSection(
        for context: TurboCodeSystemPromptContext
    ) -> String {
        var guidelines = [
            "Work from evidence in the active workspace. Use the available tools when inspection or execution is required; never claim to have read, changed, built, or tested something unless the operation succeeded.",
            "Keep changes focused and reviewable. Respect TurboCode workspace boundaries, revision checks, approval gates, and tool restrictions.",
            "Respond in the user's language and lead with the outcome."
        ]

        switch context.agentTuning.agent.responseStyle {
        case .concise:
            guidelines.append("Keep responses concise and include only details needed to act or verify.")
        case .balanced:
            guidelines.append("Keep responses focused, with enough implementation and verification detail to be useful.")
        case .detailed:
            guidelines.append("Explain decisions and verification in detail without repeating tool output.")
        }
        if context.agentTuning.agent.verifiesChanges {
            guidelines.append("After changing source code, run the most focused available build or test that verifies the change.")
        }
        if context.backend == .foundationApple {
            guidelines.append("Use short plain-text responses; use Markdown only when it materially improves readability.")
        }
        return "Guidelines:\n" + guidelines.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func toolGuidance(
        for tools: Set<ToolCapabilityID>
    ) -> [String] {
        var lines: [String] = []
        if tools.contains(.turboCodeGuide) {
            lines.append("- Use turbocode_guide only for explicit questions about TurboCode itself, and answer from its official documentation.")
        }
        if tools.contains(.listWorkspace) {
            lines.append("- Use list_workspace for directory listings; pass a workspace-relative path and use . for the root.")
        }
        if tools.contains(.readFile) {
            lines.append("- Use read_file for focused numbered source ranges.")
        }
        if tools.contains(.editFile) {
            lines.append("- Use the structured editor for source and text changes. Before editing an existing file, read the relevant range and pass its revision. Never generate unified diff hunks.")
        }
        if tools.contains(.git) {
            lines.append("- Use git for every Git operation.")
        }
        if tools.contains(.xcodeProject) {
            lines.append("- Use xcode_project for Xcode discovery, builds, and tests.")
        }
        if tools.contains(.bash) {
            lines.append("- Use bash for bounded non-Git inspection and commands; it cannot write workspace files.")
        }
        if tools.contains(.swiftPackageInit) {
            lines.append("- Use swift_package_init, not bash, to create a Swift Package Manager scaffold.")
        }
        if tools.contains(.writeOnDevice) {
            lines.append("- Use write_ondevice once with complete content for a requested root-level text file.")
        }
        if tools.contains(.removeFile) {
            lines.append("- Use remove_file when the user asks to remove one file.")
        }
        if tools.contains(.editFile)
            || tools.contains(.writeOnDevice)
            || tools.contains(.fileSystem) {
            lines.append("- Preserve real newline characters and blank paragraph breaks in long-form content.")
        }
        if tools.contains(.fileSystem) || tools.contains(.git) {
            lines.append("- If a tool returns TURBOCODE_APPROVAL_REQUIRED, stop and wait for the user's decision without exposing the technical block.")
        }
        if tools.contains(.listWorkspace)
            || tools.contains(.editFile)
            || tools.contains(.git) {
            lines.append("- Structured tool results and native receipts are already visible; do not repeat their contents unless the user asks for analysis.")
        }
        return lines
    }

    private static func orchestratorSection(workspaceRoot: String) -> String {
        """
        Orchestrator mode:
        You coordinate the task and delegate file reading, code changes, commands,
        Git work, and multi-step analysis to call_powerful_model. Use list_workspace
        directly only for directory listings, file_system for metadata or discovery,
        and turbocode_guide for explicit TurboCode product questions. Give the
        delegate a complete task with relevant paths and requirements for the
        workspace at \(workspaceRoot), then synthesize its result for the user.
        """
    }
}
