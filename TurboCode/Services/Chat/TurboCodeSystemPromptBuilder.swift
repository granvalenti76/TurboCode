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
    /// Present only for the local and Apple on-device backends, whose prompt
    /// contract provides the product-level reasoning control.
    let reasoningEffort: ReasoningEffort?

    init(
        role: TurboCodeSystemPromptRole,
        backend: ModelBackend,
        workspaceRoot: String,
        agentTuning: AgentTuningConfig,
        toolIDs: [ToolCapabilityID],
        toolNames: [String],
        availableSkills: [TurboCodeSkillDefinition],
        workspaceInstructions: WorkspaceInstructions?,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.role = role
        self.backend = backend
        self.workspaceRoot = workspaceRoot
        self.agentTuning = agentTuning
        self.toolIDs = toolIDs
        self.toolNames = toolNames
        self.availableSkills = availableSkills
        self.workspaceInstructions = workspaceInstructions
        self.reasoningEffort = reasoningEffort
    }
}

/// Builds the shared TurboCode prompt with volatile workspace content outside
/// the deterministic prefix. Local backends may receive a compact final effort
/// reminder after that content because they are sensitive to instruction recency.
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

        if let reasoningGuidance = reasoningGuidance(for: context) {
            sections.append(reasoningGuidance)
        }

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
                This workspace is the default working directory.
                You can create and maintain TurboCode TypeScript plugins autonomously.
                The SDK, documentation, and examples are installed in ~/.turbocode/sdk;
                inspect them to learn the current plugin contract.
                TypeScript plugins are installed in ~/.turbocode/plugins.
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

        if let reasoningReminder = finalReasoningReminder(for: context) {
            sections.append(reasoningReminder)
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

    /// Llama's OpenAI-compatible transport has no reasoning-effort request
    /// field, and Apple On-Device needs a consistent product-level policy.
    /// Keep this guidance out of hosted providers that expose native controls.
    private static func reasoningGuidance(
        for context: TurboCodeSystemPromptContext
    ) -> String? {
        guard let effort = context.reasoningEffort else { return nil }

        let runtime: String
        switch context.backend {
        case .llamaServer:
            runtime = "Llama"
        case .foundationApple:
            runtime = "Apple On-Device"
        case .foundationServe, .premium, .codex:
            return nil
        }

        let instruction: String
        switch effort {
        case .low:
            instruction = "Use the shortest sound reasoning path. Resolve the request directly and do not explore alternatives unless they are necessary to avoid an error."
        case .medium:
            instruction = "Before acting, identify the important steps and verify the assumptions that materially affect the result."
        case .high:
            instruction = "Before acting, form a concrete plan, inspect relevant evidence, check important edge cases, and validate the result before replying."
        case .xhigh:
            instruction = "Treat correctness as the primary objective. Decompose the task, inspect evidence before every consequential action, test assumptions and edge cases, validate each result with available tools, and correct inconsistencies before replying. Do not guess or claim verification without evidence."
        }

        return """
        Reasoning policy (\(runtime), \(effort.rawValue)):
        \(instruction)
        """
    }

    /// Repeats the selected effort after volatile workspace instructions. Local
    /// instruction-following models are often sensitive to recency within a
    /// single system message, so this preserves the policy at the final prompt
    /// boundary without weakening project-authored constraints.
    private static func finalReasoningReminder(
        for context: TurboCodeSystemPromptContext
    ) -> String? {
        guard let effort = context.reasoningEffort else { return nil }

        let runtime: String
        switch context.backend {
        case .llamaServer:
            runtime = "Llama"
        case .foundationApple:
            runtime = "Apple On-Device"
        case .foundationServe, .premium, .codex:
            return nil
        }

        return """
        Final reasoning requirement (\(runtime), \(effort.rawValue)):
        Apply the selected reasoning policy to the entire turn. Do not reduce its required planning, evidence checks, or validation merely to answer faster. Follow this requirement together with all project instructions above.
        """
    }

    private static func toolGuidance(
        for tools: Set<ToolCapabilityID>
    ) -> [String] {
        var lines: [String] = []
        if tools.contains(.turboCodeGuide) {
            lines.append("- Use turbocode_guide only for explicit questions about TurboCode itself, and answer from its official documentation.")
        }
        if tools.contains(.listWorkspace) {
            lines.append("- Prefer list_workspace when its native Browse Directory widget is useful; pass a workspace-relative path and use . for the root. Bash remains available for directory listings.")
        }
        if tools.contains(.readFile) {
            lines.append("- read_file returns numbered UTF-8 ranges with revisions and can request approval for external paths.")
        }
        if tools.contains(.searchWorkspace) {
            lines.append("- Use ripgrep flexibly to discover files or search workspace content; narrow its optional filters only when useful.")
        }
        if tools.contains(.editFile) {
            lines.append("- Prefer edit_file when its native Review and Undo widget is useful; existing files require the revision returned by read_file. Bash remains available for file changes.")
        }
        if tools.contains(.git) {
            lines.append("- Prefer git when its native status, diff, commit, or branch widgets are useful; Bash remains available for Git commands.")
        }
        if tools.contains(.xcodeProject) {
            lines.append("- xcode_project provides Xcode discovery, builds, tests, and compact diagnostics.")
        }
        if tools.contains(.bash) {
            lines.append("- bash runs arbitrary zsh commands. It discovers the supported Node runtime. Relative paths start at the reported Working directory and cd does not persist between calls; external filesystem access pauses for host approval.")
        }
        if tools.contains(.swiftPackageManager) {
            lines.append("- swift_package_manager provides structured Swift package initialization, dependency, build, test, run, cleanup, and inspection actions.")
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
        directly only for directory listings and file_system for metadata or
        discovery. Give the delegate a complete task with relevant paths and
        requirements for the workspace at \(workspaceRoot), then synthesize its
        result for the user.
        """
    }

}
