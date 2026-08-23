import Foundation

nonisolated enum TurboCodeSystemPromptRole: Sendable {
    case microtask
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
        var sections = [
            identitySection,
            TurboCodePersonality.default.prompt,
            behaviorSection(for: context)
        ]

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

        if tools.contains(.bash) {
            sections.append(typeScriptPluginSection)
        }

        if !context.workspaceRoot.isEmpty {
            sections.append("""
                Workspace:
                \(context.workspaceRoot)
                Ordinary file operations remain inside this workspace. When the
                TypeScript plugin workflow is active, Bash uses the canonical
                TURBOCODE_PLUGIN_ROOT, TURBOCODE_SDK_ROOT, and
                TURBOCODE_SDK_PACKAGE locations described above for plugin
                installation and SDK access.
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
        You are TurboCode, a native macOS agent.
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
        if tools.contains(.searchWorkspace) {
            lines.append("- Use ripgrep flexibly to discover files or search workspace content; narrow its optional filters only when useful.")
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
            lines.append("- Use bash for bounded project commands and workflows. It discovers the supported Node runtime; for TypeScript plugins use TURBOCODE_SDK_PACKAGE for the npm SDK dependency, TURBOCODE_SDK_ROOT for SDK files, and TURBOCODE_PLUGIN_ROOT for installation.")
        }
        if tools.contains(.swiftPackageManager) {
            lines.append("- Use swift_package_manager, not bash, for supported Swift Package Manager initialization, dependency, build, test, run, resolution, cleanup, and inspection actions.")
        }
        if tools.contains(.writeOnDevice) {
            lines.append("- Use write_ondevice once with complete content for a requested root-level text file.")
        }
        if tools.contains(.removeFile) {
            lines.append("- Use remove_file when the user asks to remove one file.")
        }
        if tools.contains(.delegateTask) {
            lines.append("- delegate_task is available: use it when the user asks to delegate work, or when a bounded workspace task is better handled by the configured worker; choose coding for workspace work and text for prose-only output. Do not claim the tool is unavailable.")
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

    private static let typeScriptPluginSection = """
        TypeScript plugin workflow:
        A TurboCode TypeScript plugin is a normal Node/npm project with plugin.json
        at its root and a compiled entrypoint declared by that manifest. Build it
        in the active workspace with the installed @granvalenti/turbocode-sdk,
        using TURBOCODE_SDK_PACKAGE for the npm dependency. Install the validated
        runtime under TURBOCODE_PLUGIN_ROOT/<manifest.id>, then inspect
        the installed files and reload discovery before reporting completion.
        The plugin project, its tools, and its widgets are designed by the model
        for the user's task; skills and .codex-plugin bundles are separate product
        concepts with separate layouts.
        """

}
