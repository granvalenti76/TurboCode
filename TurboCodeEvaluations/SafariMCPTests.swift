import Foundation
import Testing
@testable import TurboCode

@MainActor
@Suite("Safari MCP")
struct SafariMCPTests {
    @Test("Safari MCP is disabled by default")
    func defaultsToDisabled() {
        #expect(!AgentTuningConfig.default.experimental.safariMCPEnabled)
    }

    @Test("Legacy agent configuration keeps Safari MCP disabled")
    func legacyConfigurationDefaultsToDisabled() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1
        ])
        let decoded = try JSONDecoder().decode(AgentTuningConfig.self, from: data)
        #expect(!decoded.experimental.safariMCPEnabled)
    }

    @Test("Safari capability is added only after the experimental opt-in")
    func capabilityIsGated() {
        let disabled = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .standard,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: true,
                hasDelegateModel: false,
                repositoryMapDetail: nil
            )
        )
        #expect(!disabled.registeredIDs.contains(.safariMCP))

        let enabled = ModelToolCatalog.plan(
            profile: .standalone,
            tier: .standard,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: true,
                safariMCPEnabled: true,
                hasDelegateModel: false,
                repositoryMapDetail: nil
            )
        )
        #expect(enabled.registeredIDs.contains(.safariMCP))
    }

    @Test("Safari capability never reaches delegated workers")
    func delegatePlanRemainsBounded() {
        let plan = ModelToolCatalog.plan(
            profile: .delegate,
            tier: .standard,
            context: ToolAccessContext(
                hasWorkspace: true,
                hasSkills: true,
                safariMCPEnabled: true,
                hasDelegateModel: true,
                repositoryMapDetail: nil
            )
        )
        #expect(!plan.registeredIDs.contains(.safariMCP))
    }

    @Test("Codex advertises Safari only when the setting is enabled")
    func codexSpecificationIsGated() {
        let disabled = CodexTurboCodeToolBridge.specifications(
            workspaceRoot: "/tmp/workspace",
            agentTuning: .default
        )
        #expect(!disabled.contains(where: { $0.name == ToolCapabilityID.safariMCP.rawValue }))

        let enabled = CodexTurboCodeToolBridge.specifications(
            workspaceRoot: "/tmp/workspace",
            agentTuning: AgentTuningConfig(
                experimental: ExperimentalPolicy(safariMCPEnabled: true)
            ),
            safariMCPEnabled: true
        )
        #expect(enabled.contains(where: { $0.name == ToolCapabilityID.safariMCP.rawValue }))
    }

    @Test("Disabled gateway does not start Safari")
    func disabledGatewayIsInert() async throws {
        let tool = SafariMCPTool(enabled: false)
        let output = try await tool.call(
            arguments: SafariMCPArguments(
                operation: "list_tools",
                toolName: nil,
                argumentsJSON: nil
            )
        )
        #expect(output.contains("disabled"))
    }

    @Test("Safari context recovery prefers the active tab handle")
    func contextRecoverySelectsActiveTab() {
        let result = SafariMCPJSONValue.object([
            "content": .array([
                .object([
                    "text": .string(
                        "{\"tabs\":[{\"handle\":\"background\",\"active\":false},{\"handle\":\"current\",\"active\":true}]}"
                    )
                ])
            ])
        ])

        #expect(SafariMCPClient.preferredTabHandle(from: result) == "current")
        #expect(SafariMCPClient.isMissingBrowsingContext(
            "Command failed: performApplicationCommand: Could not find browsing context"
        ))
    }

    @Test("Disabled profiles omit the reserved Safari skill")
    func disabledProfilesFilterSafariSkill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboCode-SafariSkill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let safariURL = root.appendingPathComponent("safari/SKILL.md")
        let normalURL = root.appendingPathComponent("notes/SKILL.md")
        try FileManager.default.createDirectory(
            at: safariURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: normalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        ---
        name: safari-mcp
        description: Control Safari through MCP.
        ---
        Safari instructions.
        """.write(to: safariURL, atomically: true, encoding: .utf8)
        try """
        ---
        name: notes
        description: Keep notes concise.
        ---
        Notes instructions.
        """.write(to: normalURL, atomically: true, encoding: .utf8)

        let skills = try [
            TurboCodeSkillDefinition(contentsOf: safariURL),
            TurboCodeSkillDefinition(contentsOf: normalURL)
        ]
        let filtered = DynamicProfileRuntimeSelection.skills(
            from: skills,
            profile: nil,
            safariMCPEnabled: false
        )

        #expect(filtered.map(\.name) == ["notes"])
    }
}
