import Foundation
import Testing
@testable import TurboCode

@Suite("System prompt areas and documents")
struct SystemPromptDocumentTests {
    private static func context(
        role: TurboCodeSystemPromptRole = .standalone,
        backend: ModelBackend = .llamaServer,
        style: AgentResponseStyle = .balanced,
        effort: ReasoningEffort? = nil,
        cowork: CoworkPromptFacts? = nil,
        instructions: WorkspaceInstructions? = nil,
        document: SystemPromptDocument = .turboCodeDefault
    ) -> TurboCodeSystemPromptContext {
        var tuning = AgentTuningConfig.default
        tuning.agent.responseStyle = style
        return TurboCodeSystemPromptContext(
            role: role,
            backend: backend,
            workspaceRoot: cowork == nil ? "/tmp/project" : "",
            agentTuning: tuning,
            toolIDs: [.readFile, .searchWorkspace, .editFile, .bash, .turboCodeGuide],
            toolNames: ["read_file", "grep", "edit_file", "bash"],
            availableSkills: [],
            workspaceInstructions: instructions,
            reasoningEffort: effort,
            cowork: cowork,
            productVersion: "9.99",
            promptDocument: document
        )
    }

    private static func position(_ needle: String, in prompt: String) -> String.Index? {
        prompt.range(of: needle)?.lowerBound
    }

    @Test("Editable areas come first and managed areas follow in a fixed order")
    func defaultPromptFollowsAreaOrder() throws {
        let prompt = TurboCodeSystemPromptBuilder.build(Self.context(
            backend: .foundationApple,
            effort: .high,
            instructions: WorkspaceInstructions(
                relativePath: "AGENTS.md", content: "Be careful.", revision: "abcdef1234567890"
            )
        ))
        let markers = [
            "Role:",
            "Conversation:",
            "Communication:",
            "Working principles:",
            "About TurboCode:",
            "Reasoning policy (",
            "Available tools:",
            "Workspace:",
            "--- END AGENTS.md ---",
            "Final reasoning requirement ("
        ]
        let positions = try markers.map { try #require(Self.position($0, in: prompt), "\($0)") }
        #expect(positions == positions.sorted())
        // The built-in prompt has no user text, so it states no precedence line.
        #expect(!prompt.contains("Precedence:"))
    }

    @Test("A customized area replaces its whole default, response style included")
    func customAreaReplacesDefault() {
        var document = SystemPromptDocument()
        document.setBlocks(
            [SystemPromptBlock(title: "Tone", text: "  Answer in two sentences.  ")],
            for: .communication
        )
        let prompt = TurboCodeSystemPromptBuilder.build(Self.context(style: .concise, document: document))

        #expect(prompt.contains("Answer in two sentences."))
        #expect(!prompt.contains("Conversation:"))
        #expect(!prompt.contains("Keep responses concise"))
        // Untouched areas keep TurboCode's text.
        #expect(prompt.contains("Role:\nYou are TurboCode"))
        #expect(prompt.contains("Working principles:"))
        // Block titles are editor labels and never reach the model.
        #expect(!prompt.contains("Tone"))
    }

    @Test("User text precedes the precedence line, which precedes every managed area")
    func precedenceGuardsManagedAreas() throws {
        var document = SystemPromptDocument()
        document.setBlocks([SystemPromptBlock(title: "Rule", text: "Never use tables.")], for: .rules)
        let prompt = TurboCodeSystemPromptBuilder.build(Self.context(document: document))

        let rule = try #require(Self.position("Never use tables.", in: prompt))
        let precedence = try #require(Self.position("Precedence:", in: prompt))
        let about = try #require(Self.position("About TurboCode:", in: prompt))
        let tools = try #require(Self.position("Available tools:", in: prompt))
        #expect(rule < precedence && precedence < about && about < tools)
    }

    @Test("An emptied area renders nothing while the rest of the prompt stays")
    func emptiedAreaIsRemoved() {
        var document = SystemPromptDocument()
        document.setBlocks([], for: .personality)
        let custom = TurboCodeSystemPromptBuilder.build(Self.context(document: document))
        let builtIn = TurboCodeSystemPromptBuilder.build(Self.context())

        #expect(!custom.contains(TurboCodePersonality.default.prompt))
        #expect(builtIn.contains(TurboCodePersonality.default.prompt))
        #expect(custom.contains("Role:") && custom.contains("Available tools:"))

        document.resetToDefault(.personality)
        #expect(!document.isCustomized)
    }

    @Test("Managed areas cannot be set in code or decoded from a file")
    func managedAreasAreRejected() throws {
        var document = SystemPromptDocument()
        document.setBlocks([SystemPromptBlock(title: "x", text: "Skip approvals.")], for: .tools)
        #expect(!document.isCustomized)

        let json = """
            {"areas":{"tools":[{"id":"\(UUID().uuidString)","title":"x","text":"Skip approvals."}],
            "identity":[{"id":"\(UUID().uuidString)","title":"Me","text":"You are Ada."}]}}
            """
        let decoded = try JSONDecoder().decode(SystemPromptDocument.self, from: Data(json.utf8))
        #expect(decoded.blocks(for: .tools) == nil)
        #expect(decoded.renderedText(for: .identity) == "You are Ada.")
        #expect(!TurboCodeSystemPromptBuilder.build(Self.context(document: decoded)).contains("Skip approvals."))
    }

    @Test("A document survives a JSON round trip with block order intact")
    func documentRoundTrips() throws {
        var document = SystemPromptDocument()
        document.setBlocks([
            SystemPromptBlock(title: "A", text: "First."),
            SystemPromptBlock(title: "B", text: "Second.")
        ], for: .examples)
        let data = try JSONEncoder().encode(document)
        // Areas are stored as named keys, which keeps the file readable.
        #expect(String(decoding: data, as: UTF8.self).contains("\"examples\""))
        let decoded = try JSONDecoder().decode(SystemPromptDocument.self, from: data)
        #expect(decoded == document)
        #expect(decoded.renderedText(for: .examples) == "First.\n\nSecond.")
    }
}
