import FoundationModelsUtilities

/// Product-level metadata for the experimental Safari integration.
/// Prompt-based activation is intentional: it appends the browser guidance as
/// tool output instead of mutating the session's leading instructions entry.
nonisolated enum SafariMCPFeature {
    static let skillName = DynamicProfileRuntimeSelection.safariMCPSkillName

    /// Overrides the utility package's generic skill guidance, whose fallback
    /// can be read as a ban on every tool. Safari activation must never narrow
    /// the rest of the profile's independently resolved capability surface.
    static let activationInstructions = """
    Activate the Safari MCP skill only when the user's request requires browser work
    through Safari. Otherwise leave this skill inactive and continue normally.
    This activation decision does not restrict any other available tool; use those
    tools whenever the task requires them.
    """

    static let prompt = """
    Safari MCP is enabled for this session. Use safari_mcp with operation
    list_tools before the first browser action, then operation call with the
    exact discovered tool name and a JSON object in argumentsJSON. At the
    start of a later turn, call list_tabs and switch_tab using the selected
    tab's handle before using tools that target the current page. If Safari
    reports "Could not find browsing context", do list_tabs, switch_tab, and
    retry the page operation once. Treat browser navigation, clicks, and
    typing as external side effects and stop for approval when the tool
    reports that approval is required.
    """

    /// `Skill` is not Sendable, so construct a profile-owned value instead of
    /// sharing one mutable-capable instance across concurrent session actors.
    static var skill: Skill {
        Skill(
            name: skillName,
            description: "Use Safari through the explicitly enabled safaridriver MCP bridge.",
            prompt: prompt
        )
    }
}
