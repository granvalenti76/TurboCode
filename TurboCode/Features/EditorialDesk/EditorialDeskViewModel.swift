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
    var documentTitle = ""
    var documentDeck = ""
    var documentContent = ""
    var intakeText = ""
    var intakeName = ""
    var sources: [EditorialSource] = []
    var selectedSourceIDs: Set<UUID> = []
    var isSourceImporterPresented = false
    var importError: String?
    var operationPhase: EditorialOperationPhase = .idle
    var result: EditorialResult?
    var modelError: String?
    private var operationGeneration: UInt64 = 0

    var isRunning: Bool { operationPhase.isActive }
    var isCancelling: Bool { operationPhase == .cancelling }
    /// The custom article canvas edits a single draft snapshot. Revision stacks
    /// stay local to the modal so applying model output is always reversible.
    var draftText = ""
    private var undoStack: [String] = []
    private var redoStack: [String] = []
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

    /// Copies the visible editor fields without serializing them. Consumers
    /// must perform document encoding after crossing the UI boundary.
    func makeDraftSnapshot() -> EditorialDraftSnapshot {
        EditorialDraftSnapshot(
            title: documentTitle,
            deck: documentDeck,
            body: documentContent,
            revision: draftRevision
        )
    }

    func loadDraft(_ text: String) {
        replaceDraftState(with: text)
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Keeps the visible title, deck and body fields synchronized with the
    /// local draft projection. External prompt or Markdown encoding happens
    /// only after a Sendable snapshot crosses the UI boundary.
    func updateTitle(_ title: String) {
        documentTitle = title
        rebuildDraft()
    }

    func updateDeck(_ deck: String) {
        documentDeck = deck
        rebuildDraft()
    }

    func updateBody(_ body: String) {
        documentContent = body
        rebuildDraft()
    }

    /// Applies only the model's proposed document. Findings remain visible so
    /// the editor can review what changed after accepting the revision.
    func applyRevision() {
        guard let revisedDocument = result?.revisedDocument,
              !revisedDocument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              revisedDocument != draftText else { return }
        undoStack.append(draftText)
        replaceDraftState(with: revisedDocument)
        redoStack.removeAll()
    }

    func undoDraft() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(draftText)
        replaceDraftState(with: previous)
    }

    func redoDraft() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(draftText)
        replaceDraftState(with: next)
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
        sources.append(source)
        selectedSourceIDs.insert(source.id)
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
            workspaceRoot: workspaceRoot
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

    private func rebuildDraft() {
        draftText = [documentTitle, documentDeck, documentContent]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        draftRevision &+= 1
    }

    private func replaceDraftState(with text: String) {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        draftText = text
        if paragraphs.count >= 3 {
            documentTitle = paragraphs[0]
            documentDeck = paragraphs[1]
            documentContent = paragraphs.dropFirst(2).joined(separator: "\n\n")
        } else {
            documentTitle = ""
            documentDeck = ""
            documentContent = text
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
