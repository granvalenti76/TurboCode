import Foundation
import Observation

/// Owns only the transient state of one editorial desk presentation. It does
/// not write conversations or own provider state; the injected client keeps
/// this module removable as one feature boundary.
@MainActor
@Observable
final class EditorialDeskViewModel {
    let workspaceRoot: String
    private let modelClient: (any EditorialModelClient)?

    var selectedTab: EditorialDeskTab = .write
    private var draft = EditorialDraft()
    var documentTitle: String { draft.title }
    var documentDeck: String { draft.deck }
    var documentContent: String { draft.body }
    var intakeText = ""
    var intakeName = ""
    var sources: [EditorialSource] = []
    var selectedSourceIDs: Set<UUID> = []
    var isSourceImporterPresented = false
    var importError: String?
    var operationPhase: EditorialOperationPhase = .idle
    var result: EditorialResult? {
        didSet {
            var statuses: [UUID: EditorialFindingStatus] = [:]
            for finding in result?.findings ?? [] {
                statuses[finding.id] = .open
            }
            findingStatuses = statuses
            revisionDecisions.removeAll()
            revision = result.flatMap {
                makeRevision(for: $0, base: makeDraftSnapshot())
            }
        }
    }
    private(set) var revision: EditorialRevision?
    private(set) var lastAction: EditorialAction?
    var modelError: String?
    private var revisionDecisions: [EditorialDraftField: EditorialRevisionChangeStatus] = [:]
    private var findingStatuses: [UUID: EditorialFindingStatus] = [:]
    private var operationGeneration: UInt64 = 0

    var isRunning: Bool { operationPhase.isActive }
    var isCancelling: Bool { operationPhase == .cancelling }
    /// The custom article canvas edits one semantic draft. Revision stacks stay
    /// local to the modal so applying model output is always reversible.
    var draftText: String { draft.document }
    private var undoStack: [EditorialDraft] = []
    private var redoStack: [EditorialDraft] = []
    private enum DraftField: Equatable {
        case title
        case deck
        case body
    }
    private var activeEditField: DraftField?
    /// Monotonic identity for immutable draft snapshots. It is not persisted;
    /// it only lets an async operation describe exactly which UI state it used.
    private var draftRevision: UInt64 = 0
    private var operationTask: Task<Void, Never>?

    init(
        workspaceRoot: String,
        modelClient: (any EditorialModelClient)? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.modelClient = modelClient
    }

    var selectedSources: [EditorialSource] {
        sources.filter { selectedSourceIDs.contains($0.id) }
    }

    var canCreateDocumentFromPaste: Bool {
        canCommitIntake
    }

    var canCommitIntake: Bool {
        !intakeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasDocument: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canUndoDraft: Bool { !undoStack.isEmpty }
    var canRedoDraft: Bool { !redoStack.isEmpty }

    var revisionStatus: EditorialRevisionStatus? {
        guard let revision, !revision.isEmpty else { return nil }
        let statuses = revision.changes.map { revisionDecisions[$0.field] ?? .pending }
        if statuses.allSatisfy({ $0 == .applied }) { return .applied }
        if statuses.allSatisfy({ $0 == .rejected }) { return .rejected }
        if statuses.allSatisfy({ $0 == .pending }) { return .pending }
        return .partial
    }

    var canApplyRevision: Bool {
        guard let revision else { return false }
        return revision.changes.contains {
            (revisionDecisions[$0.field] ?? .pending) == .pending
        }
    }

    func revisionStatus(for field: EditorialDraftField) -> EditorialRevisionChangeStatus {
        revisionDecisions[field] ?? .pending
    }

    func findingStatus(for id: UUID) -> EditorialFindingStatus {
        findingStatuses[id] ?? .open
    }

    func acknowledgeFinding(_ id: UUID) {
        guard findingStatuses[id] != nil else { return }
        findingStatuses[id] = .acknowledged
    }

    func dismissFinding(_ id: UUID) {
        guard findingStatuses[id] != nil else { return }
        findingStatuses[id] = .dismissed
    }

    /// Copies the visible editor fields without serializing them. Consumers
    /// must perform document encoding after crossing the UI boundary.
    func makeDraftSnapshot() -> EditorialDraftSnapshot {
        EditorialDraftSnapshot(draft: draft, revision: draftRevision)
    }

    func loadDraft(_ draft: EditorialDraft) {
        self.draft = draft
        undoStack.removeAll()
        redoStack.removeAll()
        activeEditField = nil
        result = nil
        lastAction = nil
        draftRevision &+= 1
    }

    /// The string overload is retained for intake compatibility. Imported or
    /// pasted material is a body, never an implicit title/deck structure.
    func loadDraft(_ text: String) {
        loadDraft(EditorialDraft(body: text))
    }

    /// Keeps the visible title, deck and body fields synchronized with the
    /// local draft projection. External prompt or Markdown encoding happens
    /// only after a Sendable snapshot crosses the UI boundary.
    func updateTitle(_ title: String) {
        updateField(.title, value: title)
    }

    func updateDeck(_ deck: String) {
        updateField(.deck, value: deck)
    }

    func updateBody(_ body: String) {
        updateField(.body, value: body)
    }

    /// Applies every still-pending field in the model proposal. The proposal
    /// remains visible after applying so the editor can inspect its evidence.
    func applyRevision() {
        applyAllRevision()
    }

    func applyRevision(for field: EditorialDraftField) {
        guard let revision,
              let change = revision.changes.first(where: { $0.field == field }),
              revisionStatus(for: field) == .pending else { return }
        undoStack.append(draft)
        setDraftField(field, value: change.after)
        revisionDecisions[field] = .applied
        activeEditField = nil
        redoStack.removeAll()
        draftRevision &+= 1
    }

    func applyAllRevision() {
        guard let revision else { return }
        let pendingChanges = revision.changes.filter {
            (revisionDecisions[$0.field] ?? .pending) == .pending
        }
        guard !pendingChanges.isEmpty else { return }
        undoStack.append(draft)
        for change in pendingChanges {
            setDraftField(change.field, value: change.after)
            revisionDecisions[change.field] = .applied
        }
        activeEditField = nil
        redoStack.removeAll()
        draftRevision &+= 1
    }

    func rejectRevision(for field: EditorialDraftField) {
        guard revision?.changes.contains(where: { $0.field == field }) == true,
              revisionStatus(for: field) == .pending else { return }
        revisionDecisions[field] = .rejected
    }

    func rejectRevision() {
        guard let revision else { return }
        for change in revision.changes where revisionStatus(for: change.field) == .pending {
            revisionDecisions[change.field] = .rejected
        }
    }

    func undoDraft() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(draft)
        draft = previous
        activeEditField = nil
        synchronizeRevisionDecisions()
        draftRevision &+= 1
    }

    func redoDraft() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(draft)
        draft = next
        activeEditField = nil
        synchronizeRevisionDecisions()
        draftRevision &+= 1
    }

    func usePasteAsDocument() {
        useIntakeAsDocument()
    }

    func addPastedSource() {
        addIntakeAsSource()
    }

    /// Promotes material from any intake tab to the working draft. The source
    /// tab remains a reversible input mode; only this action changes the draft.
    func useIntakeAsDocument() {
        let content = intakeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        loadDraft(intakeText)
        selectedTab = .write
    }

    /// Adds intake material as ground truth without forcing it into the draft.
    /// Notes and transcripts retain their provenance for later review.
    func addIntakeAsSource() {
        let content = intakeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let origin: EditorialSourceOrigin = switch selectedTab {
        case .paste: .pasted
        case .notes: .notes
        case .transcript: .transcript
        case .write: .pasted
        }
        let fallbackName = switch selectedTab {
        case .paste: "Pasted source"
        case .notes: "Notes source"
        case .transcript: "Transcript source"
        case .write: "Editorial source"
        }
        let source = EditorialSource(
            name: intakeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallbackName
                : intakeName,
            origin: origin,
            content: intakeText
        )
        guard !sources.contains(where: { $0.provenanceKey == source.provenanceKey }) else {
            importError = EditorialSourceLoadError.duplicate(source.name).localizedDescription
            return
        }
        sources.append(source)
        selectedSourceIDs.insert(source.id)
        importError = nil
    }

    /// Imports selected files through an actor-owned service. Only the
    /// Sendable batch result returns to this UI-owned model, preserving
    /// successful imports when another selected file fails.
    func importFiles(
        _ urls: [URL],
        using sourceService: EditorialSourceService
    ) async {
        importError = nil
        let result = await sourceService.load(
            urls: urls,
            workspaceRoot: workspaceRoot,
            excluding: sources
        )
        sources.append(contentsOf: result.sources)
        for source in result.sources {
            selectedSourceIDs.insert(source.id)
        }
        if !result.errors.isEmpty {
            importError = result.errors.joined(separator: "\n")
        }
    }

    func toggleSource(_ id: UUID) {
        if selectedSourceIDs.contains(id) {
            selectedSourceIDs.remove(id)
        } else {
            selectedSourceIDs.insert(id)
        }
    }

    func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        selectedSourceIDs.remove(id)
    }

    func renameSource(_ id: UUID, to name: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].name = name
    }

    private func setDraftField(_ field: EditorialDraftField, value: String) {
        switch field {
        case .title: draft.title = value
        case .deck: draft.deck = value
        case .body: draft.body = value
        }
    }

    private func synchronizeRevisionDecisions() {
        guard let revision else { return }
        for change in revision.changes {
            let currentValue: String = switch change.field {
            case .title: draft.title
            case .deck: draft.deck
            case .body: draft.body
            }
            revisionDecisions[change.field] = currentValue == change.after ? .applied : .pending
        }
    }

    private func makeRevision(
        for result: EditorialResult,
        base: EditorialDraftSnapshot
    ) -> EditorialRevision? {
        let proposedDraft: EditorialDraft?
        if let revisedDraft = result.revisedDraft {
            proposedDraft = revisedDraft
        } else if let revisedDocument = result.revisedDocument,
                  !revisedDocument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            proposedDraft = EditorialDraft(
                title: base.title,
                deck: base.deck,
                body: revisedDocument
            )
        } else {
            proposedDraft = nil
        }
        guard let proposedDraft else { return nil }
        let revision = EditorialRevision(base: base, proposed: proposedDraft)
        return revision.isEmpty ? nil : revision
    }

    /// Starts one undo group per field-edit session. SwiftUI sends one update
    /// per keystroke; coalescing consecutive updates keeps one logical undo.
    private func updateField(_ field: DraftField, value: String) {
        let currentValue: String = switch field {
        case .title: draft.title
        case .deck: draft.deck
        case .body: draft.body
        }
        guard currentValue != value else { return }
        if activeEditField != field {
            undoStack.append(draft)
            redoStack.removeAll()
            activeEditField = field
        }
        switch field {
        case .title: draft.title = value
        case .deck: draft.deck = value
        case .body: draft.body = value
        }
        draftRevision &+= 1
    }

    /// Runs an operation against an immutable snapshot of the visible draft. Capturing
    /// selected sources before awaiting keeps the ground truth stable even if
    /// the user edits the inspector while the model is working.
    func run(
        action: EditorialAction,
        snapshot: EditorialDraftSnapshot,
        userInstruction: String = "Apply the selected editorial operation to this draft."
    ) {
        guard let modelClient else {
            modelError = "The editorial model is not configured."
            return
        }
        let request = EditorialRequest(
            userInstruction: userInstruction,
            draft: snapshot,
            sources: selectedSources,
            action: action
        )
        guard !isRunning else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        lastAction = action
        operationPhase = .running
        result = nil
        modelError = nil

        operationTask = Task { [weak self] in
            do {
                let result = try await modelClient.perform(request)
                guard let self,
                      self.operationGeneration == generation,
                      self.operationPhase == .running else { return }
                self.result = result
                if action.isDiagnostic {
                    self.revision = nil
                } else {
                    self.revision = self.makeRevision(for: result, base: snapshot)
                }
                self.operationPhase = .completed
            } catch {
                guard let self,
                      self.operationGeneration == generation,
                      self.operationPhase == .running else { return }
                self.modelError = error.localizedDescription
                self.operationPhase = .failed
            }
        }
    }

    /// Cancels the admitted backend operation and waits for both the provider
    /// interrupt and the original task to unwind. The generation guard makes
    /// any late completion from that task unable to overwrite newer state.
    func cancelOperation() {
        guard operationPhase == .running, let modelClient else { return }
        operationPhase = .cancelling
        let generation = operationGeneration
        let task = operationTask
        task?.cancel()
        Task { [weak self] in
            await modelClient.cancel()
            await task?.value
            guard let self,
                  self.operationGeneration == generation,
                  self.operationPhase == .cancelling else { return }
            self.operationPhase = .idle
            self.modelError = EditorialModelError.cancelled.localizedDescription
        }
    }

}
