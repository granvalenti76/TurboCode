import FoundationModelsUtilities

/// Product-level metadata for the experimental Safari integration.
/// Prompt-based activation is intentional: it appends the browser guidance as
/// tool output instead of mutating the session's leading instructions entry.
nonisolated enum SafariMCPFeature {
    static let skillName = "safari-mcp"

    /// The utility renders this activation as a Foundation `Skill`. Product
    /// instructions establish that it is an on-demand MCP integration, kept
    /// separate from the disk-backed Markdown skill catalog.
    static let activationInstructions = """
    Safari MCP is an on-demand MCP integration, not a Markdown skill. Activate it
    only when the user's request requires browser work through Safari. Otherwise
    leave this integration inactive and continue normally. This activation decision
    does not restrict any other available tool; use those tools whenever the task
    requires them.

    `/mcp` asks you to list the currently exposed Foundation on-demand MCP
    integrations. `/skills` refers only to the disk-backed Markdown `SKILL.md`
    catalog. Plugin tools and ordinary tools are not members of either catalog.
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
