import Foundation
import FoundationModels
import FoundationModelsUtilities

/// The built-in "System Prompt Builder" skill: an interview that drafts a
/// system prompt with the user and saves it to the System Prompts library.
///
/// The user turns it on per session from the Connectors page, and the model
/// still has to activate it. Until then the session carries only the one-line
/// skill entry and its activation tool; the interview method and
/// `save_system_prompt` reach the model only after activation, so a session
/// that never builds a prompt does not pay for them.
///
/// Coding only: the save tool writes to `~/.turbocode/prompts` on the Mac,
/// which a Studio session must never do outside the approved export.
nonisolated enum SystemPromptBuilderFeature {
    /// Stored in `Conversation.connectors` next to MCP connector identifiers.
    /// Never reuse it for another feature.
    static let id = "system-prompt-builder"
    static let skillName = "system-prompt-builder"
    static let activationToolName = "activate_system_prompt_builder"
    static let displayName = "System Prompt Builder"
    static let summary = "Build a system prompt with the model: it asks questions, drafts the areas, and saves the result to System Prompts."

    /// Whether a session with these stored identifiers receives the skill.
    static func isEnabled(ids: [String], domain: SessionDomain) -> Bool {
        domain == .coding && ids.contains(id)
    }

    /// `Skill` is not Sendable, so each profile builds its own value, as
    /// `SafariMCPFeature` does.
    static func skill(library: SystemPromptLibrary = .live) -> Skill {
        Skill(
            name: skillName,
            description: "Interview the user and build a custom TurboCode system prompt, then save it to System Prompts."
        ) {
            Instructions(method)
            SaveSystemPromptTool(library: library)
        }
    }

    static let activationInstructions = """
    Activate the skill below when the user asks to create, write, or change a \
    system prompt, a persona, or a custom agent. Otherwise ignore it.
    """

    /// The interview method. Kept short: it is sent with every turn once the
    /// skill is active.
    static let method = """
    You are helping the user write a system prompt for TurboCode. It is saved \
    to the System Prompts library; the user decides later whether a profile \
    uses it. TurboCode keeps tool rules, approvals, and session details itself: \
    never write about those.

    Areas you may fill (save_system_prompt "area" value in parentheses):
    - Identity (identity): who the agent is and what it is for.
    - Personality (personality): character and attitude.
    - Communication (communication): tone, length, language, format of replies.
    - Working method (workingMethod): steps and routines.
    - User context (userContext): stable facts about the user and their projects.
    - Rules (rules): what it must always or never do, and when to ask first.
    - Examples (examples): short sample exchanges.
    An area you leave out keeps TurboCode's default text.

    Interview:
    1. Ask what the prompt is for. Usually one or more of: a personality \
    (how it talks), a workflow (what it does and when), or a specialized agent \
    (for example one that writes reports).
    2. Ask at most two or three questions per message, only about the areas \
    that purpose needs: personality uses Personality and Communication; a \
    workflow uses Working method and Rules; a specialized agent uses Identity, \
    Rules, and often Examples. Offer concrete choices when the user is unsure.
    3. Write workflow steps as moments: at session start, before editing, \
    after editing, before saying the work is done, when unsure. Write each as \
    "when X, do Y", with the reason when it is not obvious.
    4. Show the whole draft grouped by area and ask for changes. Write the \
    prompt in English unless the user asks otherwise; talk to the user in \
    their language.
    5. Only after the user approves, call save_system_prompt with a short name \
    and the blocks. Then tell them it is in System Prompts, where they can \
    refine it and choose "Use for Profile".

    Keep the prompt short and specific: every line is read on every turn.
    """
}
