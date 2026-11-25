import Foundation

/// The fixed slots of a TurboCode system prompt, in the order the builder
/// renders them.
///
/// The order is owned by TurboCode, not by the user: every prompt starts with
/// the user-editable areas and ends with the managed ones, so a profile's
/// prompt keeps a stable prefix and a provider's prompt cache survives edits
/// made elsewhere in the app. Users add, remove, and reorder blocks *inside*
/// an editable area; they never move an area. Adding a case changes the
/// persisted vocabulary, so append new areas instead of renaming raw values.
nonisolated enum SystemPromptArea: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    // User-editable areas, in reading order.
    case identity
    case personality
    case communication
    case workingMethod
    case userContext
    case rules
    case examples

    // Managed areas. TurboCode writes them from the runtime context (version,
    // backend, tools, catalogs, workspace) and a document can never replace them.
    case aboutApp
    case reasoning
    case tools
    case catalogs
    /// Studio VM contract, role-specific instructions, workspace path, and
    /// AGENTS.md: the volatile content that must stay after the stable prefix.
    case session
    case finalReminder

    /// True when TurboCode generates the area and a document cannot change it.
    var isManaged: Bool {
        switch self {
        case .identity, .personality, .communication, .workingMethod,
             .userContext, .rules, .examples:
            false
        case .aboutApp, .reasoning, .tools, .catalogs, .session, .finalReminder:
            true
        }
    }

    static let editableAreas = allCases.filter { !$0.isManaged }

    /// The name shown in the editor and matched by the Markdown importer.
    var title: String {
        switch self {
        case .identity: "Identity"
        case .personality: "Personality"
        case .communication: "Communication"
        case .workingMethod: "Working method"
        case .userContext: "User context"
        case .rules: "Rules"
        case .examples: "Examples"
        case .aboutApp: "About the app"
        case .reasoning: "Reasoning"
        case .tools: "Tools & rules"
        case .catalogs: "Catalogs"
        case .session: "Session"
        case .finalReminder: "Final reminder"
        }
    }
}

/// One user-authored piece of an editable area.
///
/// `title` is the label shown in the editor; only `text` reaches the model,
/// so renaming a block never changes the prompt or its cache.
nonisolated struct SystemPromptBlock: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var title: String
    var text: String

    init(id: UUID = UUID(), title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// The user-authored content of a system prompt: the editable areas only.
///
/// An area that is absent from `areas` keeps TurboCode's default text for the
/// current context (role, Studio or Coding, response style). An area present
/// with an empty array was removed on purpose and renders nothing. Customizing
/// an area replaces its whole default, including the lines TurboCode derives
/// from Settings such as the response style: the user's text wins there.
/// Managed areas are dropped on construction so a hand-edited or imported file
/// cannot replace tool rules, approval gates, or the workspace contract.
nonisolated struct SystemPromptDocument: Codable, Sendable, Hashable {
    private(set) var areas: [SystemPromptArea: [SystemPromptBlock]]

    init(areas: [SystemPromptArea: [SystemPromptBlock]] = [:]) {
        self.areas = areas.filter { !$0.key.isManaged }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(areas: try container.decode(
            [SystemPromptArea: [SystemPromptBlock]].self, forKey: .areas
        ))
    }

    /// The built-in prompt: every area keeps TurboCode's default text.
    static let turboCodeDefault = SystemPromptDocument()

    /// True when at least one area differs from TurboCode's default.
    var isCustomized: Bool { !areas.isEmpty }

    /// The user's blocks for `area`, or nil when the area keeps its default.
    func blocks(for area: SystemPromptArea) -> [SystemPromptBlock]? {
        areas[area]
    }

    /// Replaces an editable area's blocks; managed areas are ignored.
    mutating func setBlocks(_ blocks: [SystemPromptBlock], for area: SystemPromptArea) {
        guard !area.isManaged else { return }
        areas[area] = blocks
    }

    /// Returns an editable area to TurboCode's default text.
    mutating func resetToDefault(_ area: SystemPromptArea) {
        areas[area] = nil
    }

    /// The text a customized area sends to the model: block texts in order,
    /// trimmed, with empty blocks skipped. Nil when the area keeps its default.
    func renderedText(for area: SystemPromptArea) -> String? {
        guard let blocks = areas[area] else { return nil }
        return blocks
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
