import Foundation

/// Starting points offered by the New Prompt menu, and the size estimates the
/// library and editor show. Pure logic, so it is testable off the main actor.
nonisolated enum SystemPromptTemplates {
    /// The context a copy of the default is taken in: a Coding standalone
    /// session with the user's current Settings. Copying freezes the lines
    /// TurboCode derives from Settings (response style, verification), which
    /// is intended: a customized area owns its whole text from then on.
    static func codingContext(
        tuning: AgentTuningConfig,
        document: SystemPromptDocument = .turboCodeDefault
    ) -> TurboCodeSystemPromptContext {
        TurboCodeSystemPromptContext(
            role: .standalone,
            backend: .llamaServer,
            workspaceRoot: "",
            agentTuning: tuning,
            toolIDs: [],
            toolNames: [],
            availableSkills: [],
            workspaceInstructions: nil,
            promptDocument: document
        )
    }

    /// Every editable area filled with TurboCode's own text, one block each.
    /// Areas with no built-in text stay at their default (empty) so they do
    /// not count as customized.
    static func duplicateOfDefault(tuning: AgentTuningConfig) -> SystemPromptDocument {
        let context = codingContext(tuning: tuning)
        var document = SystemPromptDocument()
        for area in SystemPromptArea.editableAreas {
            let text = TurboCodeSystemPromptBuilder.defaultText(for: area, context: context)
            guard !text.isEmpty else { continue }
            document.setBlocks([SystemPromptBlock(title: area.title, text: text)], for: area)
        }
        return document
    }

    /// An Identity block only. Personality, communication, and working method
    /// are explicitly emptied, so a blank prompt really starts from nothing;
    /// the managed areas are still added by TurboCode.
    static func blank() -> SystemPromptDocument {
        var document = SystemPromptDocument()
        document.setBlocks([SystemPromptBlock(
            title: "Identity",
            text: "You are a helpful agent. Work with the user until their requested outcome is handled."
        )], for: .identity)
        for area in [SystemPromptArea.personality, .communication, .workingMethod] {
            document.setBlocks([], for: area)
        }
        return document
    }

    /// Turns a Markdown file into a document: each `## Heading` starts a
    /// block. A heading that names an editable area ("## Rules") puts its
    /// block there; any other heading goes to User context with the heading
    /// as the block title. Text before the first heading becomes Identity.
    /// Areas the file does not mention keep TurboCode's default, so an
    /// imported persona still gets the built-in working method.
    static func importMarkdown(_ markdown: String) -> SystemPromptDocument {
        var grouped: [SystemPromptArea: [SystemPromptBlock]] = [:]
        var title: String?
        var lines: [Substring] = []

        func flush() {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            lines = []
            guard !text.isEmpty else { return }
            let area = title.map { area(named: $0) ?? .userContext } ?? .identity
            grouped[area, default: []].append(SystemPromptBlock(title: title ?? area.title, text: text))
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        flush()

        var document = SystemPromptDocument()
        for (area, blocks) in grouped { document.setBlocks(blocks, for: area) }
        return document
    }

    private static func area(named heading: String) -> SystemPromptArea? {
        SystemPromptArea.editableAreas.first {
            $0.title.compare(heading, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// The tools a default Coding session registers on a standard remote
    /// model, used only to size the managed part of the editor's square.
    static let referenceCodingToolIDs: [ToolCapabilityID] = ModelToolCatalog.plan(
        profile: .standalone,
        tier: .standard,
        context: ToolAccessContext(
            hasWorkspace: true, hasSkills: false, hasDelegateModel: false, repositoryMapDetail: nil
        )
    ).registeredIDs.sorted { $0.rawValue < $1.rawValue }

    /// A Coding context with the reference tools, so the managed areas the
    /// editor shows include the tool list and rules a real session adds.
    static func editorContext(
        tuning: AgentTuningConfig,
        document: SystemPromptDocument
    ) -> TurboCodeSystemPromptContext {
        TurboCodeSystemPromptContext(
            role: .standalone,
            backend: .llamaServer,
            workspaceRoot: "~/project",
            agentTuning: tuning,
            toolIDs: referenceCodingToolIDs,
            toolNames: referenceCodingToolIDs.map(\.runtimeName),
            availableSkills: [],
            workspaceInstructions: nil,
            promptDocument: document
        )
    }

    /// Estimated tokens the model reads for each editable area of `document`
    /// in the Coding context, defaults included. The same four-characters
    /// estimate as the composer metrics; providers' tokenizers differ.
    static func editableTokenEstimates(
        _ document: SystemPromptDocument,
        tuning: AgentTuningConfig
    ) -> [(area: SystemPromptArea, tokens: Int)] {
        let context = codingContext(tuning: tuning)
        return SystemPromptArea.editableAreas.compactMap { area in
            let text = document.renderedText(for: area)
                ?? TurboCodeSystemPromptBuilder.defaultText(for: area, context: context)
            let tokens = CapabilityContextEstimate.estimatedTokens(for: text)
            return tokens == 0 ? nil : (area, tokens)
        }
    }

    /// Estimated tokens of the whole prompt in the Coding context without
    /// tool schemas, which depend on the model and profile at run time.
    static func totalTokenEstimate(_ document: SystemPromptDocument, tuning: AgentTuningConfig) -> Int {
        let prompt = TurboCodeSystemPromptBuilder.build(codingContext(tuning: tuning, document: document))
        return CapabilityContextEstimate.estimatedTokens(for: prompt)
    }
}
