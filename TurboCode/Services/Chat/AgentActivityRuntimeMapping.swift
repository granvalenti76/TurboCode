import FoundationModels

/// Normalizes provider-specific tool callbacks before they reach Activity.
///
/// Keeping this conversion mechanical ensures tool ownership comes from the
/// configured route, not from model-generated descriptions or reasoning.
nonisolated enum AgentActivityRuntimeMapping {
    static func tool(
        from call: Transcript.ToolCall,
        owner: AgentActivityToolOwner
    ) -> AgentActivityTool {
        AgentActivityTool(
            callID: call.id,
            name: call.toolName,
            owner: owner
        )
    }

    static func tool(
        from call: CodexDynamicToolCall,
        owner: AgentActivityToolOwner
    ) -> AgentActivityTool {
        AgentActivityTool(
            callID: call.callID,
            name: call.tool,
            owner: owner
        )
    }
}
