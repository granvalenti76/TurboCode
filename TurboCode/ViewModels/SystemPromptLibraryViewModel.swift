import Foundation
import Observation

/// State of Settings › Agents › System Prompts: the saved prompts and which
/// one each profile uses.
///
/// Reads and writes go straight to `SystemPromptLibrary` on the main actor.
/// The files are a few kilobytes each and change only on a click, so the
/// synchronous I/O stays below a frame; nothing here runs per keystroke.
/// `onPromptsChanged` fires after any change that can alter what a session
/// sends, so the caller can rebuild the session once.
@MainActor
@Observable
final class SystemPromptLibraryViewModel {
    enum SortOrder: String, CaseIterable, Identifiable {
        case name = "Name"
        case recentlyEdited = "Recently edited"
        var id: String { rawValue }
    }

    enum NewPromptKind {
        case duplicateDefault
        case blank
    }

    private let library: SystemPromptLibrary
    private let onPromptsChanged: @MainActor () -> Void

    private(set) var records: [SystemPromptRecord] = []
    private(set) var assignments = SystemPromptAssignments()
    var sortOrder: SortOrder = .name
    /// The last failed write, shown once by the view.
    var errorMessage: String?

    init(
        library: SystemPromptLibrary = .live,
        onPromptsChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.library = library
        self.onPromptsChanged = onPromptsChanged
    }

    var sortedRecords: [SystemPromptRecord] {
        switch sortOrder {
        case .name: records
        case .recentlyEdited: records.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func load() {
        records = library.records()
        assignments = library.assignments()
    }

    func record(_ id: UUID) -> SystemPromptRecord? {
        records.first { $0.id == id }
    }

    /// The profiles using a prompt; nil means the built-in default.
    func profiles(using id: UUID?) -> [SystemPromptProfile] {
        SystemPromptProfile.allCases.filter { assignments.promptIDs[$0] == id }
    }

    @discardableResult
    func create(_ kind: NewPromptKind, tuning: AgentTuningConfig) -> SystemPromptRecord? {
        let record = switch kind {
        case .duplicateDefault:
            SystemPromptRecord(
                name: uniqueName("TurboCode default copy"),
                basedOnDefault: true,
                document: SystemPromptTemplates.duplicateOfDefault(tuning: tuning)
            )
        case .blank:
            SystemPromptRecord(
                name: uniqueName("Untitled prompt"),
                basedOnDefault: false,
                document: SystemPromptTemplates.blank()
            )
        }
        return insert(record)
    }

    @discardableResult
    func importMarkdown(from url: URL) -> SystemPromptRecord? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "TurboCode could not read \(url.lastPathComponent) as text."
            return nil
        }
        let document = SystemPromptTemplates.importMarkdown(text)
        guard document.isCustomized else {
            errorMessage = "\(url.lastPathComponent) has no text to import."
            return nil
        }
        return insert(SystemPromptRecord(
            name: uniqueName(url.deletingPathExtension().lastPathComponent),
            basedOnDefault: false,
            document: document
        ))
    }

    @discardableResult
    func duplicate(_ id: UUID) -> SystemPromptRecord? {
        guard let source = record(id) else { return nil }
        return insert(SystemPromptRecord(
            name: uniqueName("\(source.name) copy"),
            basedOnDefault: source.basedOnDefault,
            document: source.document
        ))
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var record = record(id), record.name != trimmed else { return }
        record.name = trimmed
        // A rename never reaches the model, so no session rebuild.
        persist(record, notify: false)
    }

    /// Saves edited content. The record's version grows only on a real change.
    func updateDocument(_ id: UUID, to document: SystemPromptDocument) {
        guard var record = record(id) else { return }
        let before = record.version
        record.updateDocument(document)
        guard record.version != before else { return }
        persist(record, notify: !profiles(using: id).isEmpty)
    }

    func delete(_ id: UUID) {
        let wasAssigned = !profiles(using: id).isEmpty
        do {
            try library.delete(id)
        } catch {
            errorMessage = "TurboCode could not delete the prompt: \(error.localizedDescription)"
        }
        load()
        if wasAssigned { onPromptsChanged() }
    }

    /// Points a profile at a saved prompt, or at the default with nil.
    func assign(_ profile: SystemPromptProfile, to id: UUID?) {
        guard assignments.promptIDs[profile] != id else { return }
        var updated = assignments
        updated.promptIDs[profile] = id
        do {
            try library.saveAssignments(updated)
            assignments = updated
            onPromptsChanged()
        } catch {
            errorMessage = "TurboCode could not save the assignment: \(error.localizedDescription)"
        }
    }

    private func insert(_ record: SystemPromptRecord) -> SystemPromptRecord? {
        persist(record, notify: false) ? record : nil
    }

    @discardableResult
    private func persist(_ record: SystemPromptRecord, notify: Bool) -> Bool {
        do {
            try library.save(record)
        } catch {
            errorMessage = "TurboCode could not save \(record.name): \(error.localizedDescription)"
            return false
        }
        load()
        if notify { onPromptsChanged() }
        return true
    }

    /// "Name", then "Name 2", "Name 3"… so the library never shows two cards
    /// with the same title.
    private func uniqueName(_ base: String) -> String {
        let taken = Set(records.map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}
