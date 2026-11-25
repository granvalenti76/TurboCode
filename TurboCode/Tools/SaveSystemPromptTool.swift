import Foundation
import FoundationModels

/// One block of a drafted system prompt, placed in an editable area.
@Generable
struct SaveSystemPromptBlock {
    /// Editable area that receives this block.
    @Guide(.anyOf(SaveSystemPromptTool.editableAreaNames))
    var area: String
    /// Short label shown in the editor; never sent to the model.
    var title: String
    /// The text the model will read in that area.
    var text: String
}

@Generable
struct SaveSystemPromptArguments {
    /// Name of the prompt as the user will see it in System Prompts.
    var name: String
    /// Blocks in reading order. Areas left out keep TurboCode's default text.
    var blocks: [SaveSystemPromptBlock]
}

/// Saves a system prompt drafted together with the user into the System
/// Prompts library.
///
/// The tool only ever creates a new, unassigned record: it never overwrites a
/// saved prompt and never changes which prompt a profile uses. That choice
/// stays with the user on the System Prompts page, so a draft the model saves
/// cannot change the behavior of any session until the user opts in. For the
/// same reason managed areas (tool rules, approvals, session) are rejected
/// rather than silently dropped: the model must learn they are not its to set.
struct SaveSystemPromptTool: Tool {
    typealias Arguments = SaveSystemPromptArguments
    typealias Output = ToolCommandOutput

    /// Raw values of the areas a user prompt may fill, in the order TurboCode
    /// renders them.
    static let editableAreaNames = SystemPromptArea.allCases
        .filter { !$0.isManaged }
        .map(\.rawValue)

    static let maximumNameLength = 80

    let library: SystemPromptLibrary
    /// Called after a successful save so open pages and the next session see
    /// the new prompt without a relaunch.
    let onSaved: @Sendable () async -> Void

    init(
        library: SystemPromptLibrary = .live,
        onSaved: @escaping @Sendable () async -> Void = {}
    ) {
        self.library = library
        self.onSaved = onSaved
    }

    var name: String { "save_system_prompt" }
    var description: String {
        "Save a system prompt drafted with the user to the System Prompts library as a new, unassigned prompt. Call it only after the user approved the draft."
    }
    var includesSchemaInInstructions: Bool { true }

    func call(arguments: SaveSystemPromptArguments) async throws -> ToolCommandOutput {
        let document: SystemPromptDocument
        let name: String
        switch Self.validate(arguments) {
        case .failure(let failure):
            return .plain("System prompt not saved: \(failure.message)")
        case .success(let value):
            (name, document) = value
        }

        let uniqueName = Self.uniqueName(name, among: Set(library.records().map(\.name)))
        // Areas the draft does not mention keep the default text, so the
        // record is a modified copy of TurboCode's default.
        let record = SystemPromptRecord(name: uniqueName, basedOnDefault: true, document: document)
        try library.save(record)
        await onSaved()

        let areas = SystemPromptArea.allCases
            .filter { document.blocks(for: $0) != nil }
            .map(\.title)
            .joined(separator: ", ")
        return .plain("""
        Saved "\(uniqueName)" to System Prompts (areas: \(areas)). No profile uses it yet: \
        the user can open it there to refine it and choose "Use for Profile".
        """)
    }

    /// Checks the draft and groups its blocks by area, keeping their order.
    /// Pure so the rules are testable without touching disk.
    static func validate(
        _ arguments: SaveSystemPromptArguments
    ) -> Result<(name: String, document: SystemPromptDocument), ValidationFailure> {
        let name = arguments.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("\n"), name.count <= maximumNameLength else {
            return .failure(.init("name must be one line of 1 to \(maximumNameLength) characters."))
        }

        var grouped: [SystemPromptArea: [SystemPromptBlock]] = [:]
        for block in arguments.blocks {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let area = SystemPromptArea(rawValue: block.area) else {
                return .failure(.init(
                    "unknown area \"\(block.area)\". Use one of: \(editableAreaNames.joined(separator: ", "))."
                ))
            }
            guard !area.isManaged else {
                return .failure(.init(
                    "\"\(block.area)\" is managed by TurboCode and cannot be changed. Use one of: \(editableAreaNames.joined(separator: ", "))."
                ))
            }
            let title = block.title.trimmingCharacters(in: .whitespacesAndNewlines)
            grouped[area, default: []].append(
                SystemPromptBlock(title: title.isEmpty ? area.title : title, text: text)
            )
        }
        guard !grouped.isEmpty else {
            return .failure(.init("the draft has no text. Add at least one block."))
        }
        return .success((name, SystemPromptDocument(areas: grouped)))
    }

    /// Appends " 2", " 3"… so a draft never looks like a prompt the user
    /// already has; records are keyed by UUID, so this is only for clarity.
    static func uniqueName(_ name: String, among existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        var index = 2
        while existing.contains("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }

    struct ValidationFailure: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
