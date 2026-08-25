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
    var isRunning = false
    var result: EditorialResult?
    var modelError: String?
    var isCancelling = false
    /// The custom article canvas edits a single draft snapshot. Revision stacks
    /// stay local to the modal so applying model output is always reversible.
    var draftText = ""
    private var undoStack: [String] = []
    private var redoStack: [String] = []
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

    func loadDraft(_ text: String) {
        replaceDraftState(with: text)
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Keeps the visible title, deck and body fields synchronized with the
    /// serialized request sent to the model. Direct typing updates the draft
    /// without adding one undo entry per keystroke; the native text view still
    /// provides its own immediate typing undo behavior.
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

    func importFiles(_ urls: [URL]) {
        importError = nil

        for url in urls {
            do {
                let source = try EditorialSourceLoader.load(
                    from: url,
                    workspaceRoot: workspaceRoot
                )
                sources.append(source)
                selectedSourceIDs.insert(source.id)
            } catch {
                importError = error.localizedDescription
            }
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
    }

    /// Runs an operation against a snapshot of the visible draft. Capturing
    /// selected sources before awaiting keeps the ground truth stable even if
    /// the user edits the inspector while the model is working.
    func run(
        action: EditorialAction,
        document: String,
        userInstruction: String = "Apply the selected editorial operation to this draft."
    ) {
        guard let modelClient else {
            modelError = "The editorial model is not configured."
            return
        }
        let request = EditorialRequest(
            userInstruction: userInstruction,
            document: document,
            sources: selectedSources,
            action: action
        )
        isRunning = true
        isCancelling = false
        modelError = nil

        operationTask?.cancel()
        operationTask = Task { [weak self] in
            do {
                let result = try await modelClient.perform(request)
                guard let self else { return }
                self.result = result
                self.isRunning = false
                self.isCancelling = false
            } catch {
                guard let self else { return }
                self.modelError = error.localizedDescription
                self.isRunning = false
                self.isCancelling = false
            }
        }
    }

    /// Cancels the admitted backend operation before clearing the modal state.
    /// This preserves the runtime's ownership rule for provider sessions.
    func cancelOperation() {
        guard isRunning, let modelClient else { return }
        isCancelling = true
        operationTask?.cancel()
        Task { [weak self] in
            await modelClient.cancel()
            guard let self else { return }
            self.isRunning = false
            self.isCancelling = false
            self.modelError = EditorialModelError.cancelled.localizedDescription
        }
    }

}
