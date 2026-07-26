import FoundationModels
import FoundationModelsUtilities

/// Metadata kept separate from `Skill` so the workflow contract can be tested
/// without depending on Foundation Models' private rendered representation.
nonisolated struct AgentWorkflowSkillDescriptor: Sendable, Hashable {
    let name: String
    let description: String
    let prompt: String
}

/// Just-in-time playbooks for the engineering loops where smaller remote
/// models most often stop early. The primary workflows carry their tools, so
/// activation is a capability boundary rather than optional advice.
nonisolated enum AgentWorkflowSkillCatalog {
    static let descriptors: [AgentWorkflowSkillDescriptor] = [
        AgentWorkflowSkillDescriptor(
            name: "xcode-agent-loop",
            description: """
            Complete a change in an Xcode project by inspecting the project, \
            editing source, building or testing, and recovering from diagnostics.
            """,
            prompt: """
            # Xcode agent loop

            Treat the user's requested outcome, not the first file edit, as the
            completion condition.

            1. Inspect the workspace and call xcode_project with action inspect
               before guessing a container or scheme. Use swift_workspace_map,
               read_file, and grep only for the declarations and source ranges
               relevant to the request.
            2. Before modifying an existing file, read the affected range and
               pass its current Revision to edit_file. Make the smallest
               coherent change that can satisfy the request.
            3. After a source change, call xcode_project to build the affected
               scheme. Run its focused tests when the change has test coverage
               or changes observable behavior.
            4. If verification fails, use the returned file, line, and message
               as new evidence: inspect that source, correct the cause, and
               repeat the same verification. Do not merely explain the command
               the user could run.
            5. Finish only after reporting the actual build/test evidence, or
               after identifying a concrete blocker that tools cannot resolve.

            Preserve workspace boundaries and stop when a tool requests user
            approval.
            """
        ),
        AgentWorkflowSkillDescriptor(
            name: "swift-package-agent-loop",
            description: """
            Complete a Swift Package Manager task through package inspection, \
            source edits, swift build or test, and diagnostic recovery.
            """,
            prompt: """
            # Swift Package Manager agent loop

            Carry the request through a verified repository state.

            1. Inspect Package.swift and the relevant Sources and Tests paths.
               Use swift_workspace_map first when it can identify declarations
               more cheaply than reading complete files.
            2. Use swift_package_init only for a new package scaffold. For
               existing files, read the relevant range immediately before
               applying a revision-bound edit_file change.
            3. Verify manifest or source changes with the narrowest useful Swift
               command through bash: prefer swift test when tests exist and
               swift build otherwise.
            4. Treat compiler and test output as the next observation in the
               loop. Inspect the cited declaration, correct the root cause, and
               rerun the failed command.
            5. Return a final answer only when the requested state and its
               verification are both known. If the environment blocks progress,
               report the exact failed operation and evidence.

            Use git only for Git operations, never shell Git commands.
            """
        ),
        AgentWorkflowSkillDescriptor(
            name: "diagnostic-recovery",
            description: """
            Recover when an Xcode build, Swift build, test, edit, or workspace \
            tool fails instead of stopping after the first error.
            """,
            prompt: """
            # Diagnostic recovery

            A failed tool result is an observation, not automatically the end
            of the task.

            - Classify the failure as stale revision, source diagnostic, test
              failure, invalid tool input, missing project configuration,
              environment limitation, or approval boundary.
            - For a stale revision, reread the precise range and reapply the
              intended change against the new Revision.
            - For source or test diagnostics, inspect the first actionable
              project-owned location, fix the root cause, and rerun the same
              focused verification.
            - For invalid input or project selection, use discovery output to
              correct the next tool call rather than repeating it unchanged.
            - Stop immediately for an approval boundary. For an environment
              limitation, preserve the error evidence and state the blocker.
            - If two evidence-based corrections produce the same failure, stop
              guessing and report the repeated diagnostic with the attempted
              corrections.
            """
        )
    ]

    static func skills(tools: [any Tool]) -> [Skill] {
        let xcodeTools = tools.filter { $0.name != "swift_package_init" }
        let swiftPackageTools = tools.filter { $0.name != "xcode_project" }
        let xcode = descriptors[0]
        let swiftPackage = descriptors[1]
        let recovery = descriptors[2]
        return [
            Skill(
                name: xcode.name,
                description: xcode.description,
                allowsDeactivation: false
            ) {
                // Instruction-based skills can introduce tools. The one-time
                // prefix change buys a smaller, unambiguous initial surface.
                Instructions(xcode.prompt)
                xcodeTools
            },
            Skill(
                name: swiftPackage.name,
                description: swiftPackage.description,
                allowsDeactivation: false
            ) {
                Instructions(swiftPackage.prompt)
                swiftPackageTools
            },
            // Recovery adds guidance after a primary workflow already exposed
            // its tools, so it can remain a cache-friendly prompt skill.
            Skill(
                name: recovery.name,
                description: recovery.description,
                prompt: recovery.prompt
            )
        ]
    }
}

/// Adds one selector instead of placing every engineering tool schema and
/// workflow in the initial model context.
struct AgentWorkflowSkills: DynamicInstructions {
    let activations: SkillActivations
    let tools: [any Tool]

    var body: some DynamicInstructions {
        Skills(
            activations: activations,
            toolName: "load_agent_workflow",
            toolDescription: """
            Load the engineering workflow that matches the current task to gain \
            its inspection, editing, and verification tools. Load \
            diagnostic-recovery after a tool \
            failure when the next corrective action is not already clear. Do \
            not ask permission or mention loading a workflow.
            """,
            instructions: Instructions {
                """
                For Xcode and Swift Package Manager engineering requests, load \
                the matching workflow before acting. Its tools are unavailable \
                until activation, and the workflow must be followed through \
                verification.
                """
            },
            strictSchema: true,
            skills: AgentWorkflowSkillCatalog.skills(tools: tools)
        )
    }
}
