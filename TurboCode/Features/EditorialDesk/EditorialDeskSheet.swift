import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Visual mock of the editorial desk. The article canvas is custom SwiftUI
/// rather than a native TextEditor so line numbers, selection, inline actions,
/// and the inspector can match the editorial reference while provider results
/// remain projected into the modal rather than the main chat timeline.
struct EditorialDeskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @State private var viewModel: EditorialDeskViewModel
    @State private var selectedTab: EditorialDeskTab = .write
    @State private var selectedInspectorTab: EditorialDeskInspectorTab = .info
    @State private var selectedSectionID: UUID?
    @State private var selectedTypeID: UUID?
    @State private var selectedDate: Date?
    @State private var datePickerDate = Date()
    @State private var datePickerPresented = false
    @State private var hoveredAction: EditorialAction?
    @State private var actionMenuPresented = false
    @State private var editorScrollOffset: CGFloat = 0
    @State private var sourceImporterPresented = false
    @State private var renameSourceID: UUID?
    @State private var renameSourceText = ""
    @State private var publicationCoordinator: EditorialPublicationCoordinator
    @State private var publishError: String?
    @State private var draftDescriptors: [EditorialDraftDescriptor] = []
    @State private var selectedDraftPath: String?
    @State private var activeDraftID = UUID()
    @State private var savedDraftRevision: UInt64 = 0
    @State private var savedDraftMetadata: EditorialDeskMetadata = .empty
    @State private var isLoadingDrafts = false
    @State private var draftLibraryError: String?
    @State private var pendingDraftSelection: PendingDraftSelection?

    private let workspaceRoot: String
    private let dependencies: EditorialDeskDependencies

    private enum PendingDraftSelection {
        case newDraft
        case existing(String)
        case dismiss
    }

    private var isPublishing: Bool {
        publicationCoordinator.isActive
    }

    init(
        workspaceRoot: String,
        dependencies: EditorialDeskDependencies
    ) {
        self.workspaceRoot = workspaceRoot
        self.dependencies = dependencies
        let viewModel = EditorialDeskViewModel(
            workspaceRoot: workspaceRoot,
            modelClient: dependencies.modelClient
        )
        _viewModel = State(initialValue: viewModel)
        _publicationCoordinator = State(
            initialValue: EditorialPublicationCoordinator(
                publicationService: dependencies.publicationService,
                receiptPresenter: dependencies.receiptPresenter
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorialDeskTitleBar()
            EditorialDeskToolbar(
                selectedTab: $selectedTab,
                onSelectTab: { tab in viewModel.selectedTab = tab },
                onUndo: { viewModel.undoDraft() },
                onRedo: { viewModel.redoDraft() },
                draftName: selectedDraftName,
                draftDescriptors: draftDescriptors,
                selectedDraftPath: selectedDraftPath,
                hasUnsavedChanges: hasUnsavedDraftChanges,
                isLoadingDrafts: isLoadingDrafts,
                onNewDraft: { requestDraftSelection(.newDraft) },
                onSelectDraft: { requestDraftSelection(.existing($0)) }
            )
            EditorialDeskMetadataBar(
                selectedSectionID: $selectedSectionID,
                selectedTypeID: $selectedTypeID,
                hasDocument: viewModel.hasDocument,
                selectedSourceCount: viewModel.selectedSources.count,
                totalSourceCount: viewModel.sources.count
            )
            Divider()

            HStack(spacing: 0) {
                EditorialDeskArticleCanvas(
                    viewModel: viewModel,
                    selectedTab: $selectedTab,
                    hoveredAction: $hoveredAction,
                    actionMenuPresented: $actionMenuPresented,
                    editorScrollOffset: $editorScrollOffset
                )
                EditorialDeskInspector(
                    viewModel: viewModel,
                    selectedTab: $selectedInspectorTab,
                    sourceImporterPresented: $sourceImporterPresented,
                    renameSourceID: $renameSourceID,
                    renameSourceText: $renameSourceText,
                    selectedDate: $selectedDate,
                    datePickerDate: $datePickerDate,
                    datePickerPresented: $datePickerPresented
                )
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)

            Divider()
            EditorialDeskFooter(
                viewModel: viewModel,
                isPublishing: isPublishing,
                onDismiss: { requestDraftSelection(.dismiss) },
                onPublish: { publishDraft() }
            )
        }
        .frame(minWidth: 1120, idealWidth: 1240, minHeight: 700, idealHeight: 820)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await refreshDraftLibrary()
        }
        .fileImporter(
            isPresented: $sourceImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                selectedInspectorTab = .sources
                Task { @MainActor in
                    await viewModel.importFiles(
                        urls,
                        using: dependencies.sourceService
                    )
                }
            case .failure(let error):
                viewModel.importError = error.localizedDescription
            }
        }
        .alert(
            "Rename source",
            isPresented: Binding(
                get: { renameSourceID != nil },
                set: { if !$0 { renameSourceID = nil } }
            )
        ) {
            TextField("Source name", text: $renameSourceText)
            Button("Save") {
                if let renameSourceID {
                    viewModel.renameSource(renameSourceID, to: renameSourceText)
                }
                self.renameSourceID = nil
            }
            Button("Cancel", role: .cancel) {
                renameSourceID = nil
            }
        } message: {
            Text("Use a name that helps the desk identify this ground-truth material.")
        }
        .alert(
            "Publish Draft",
            isPresented: Binding(
                get: { publishError != nil },
                set: { if !$0 { publishError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { publishError = nil }
        } message: {
            Text(publishError ?? "The draft could not be published.")
        }
        .alert(
            "Discard unsaved changes?",
            isPresented: Binding(
                get: { pendingDraftSelection != nil },
                set: { if !$0 { pendingDraftSelection = nil } }
            )
        ) {
            Button("Discard Changes", role: .destructive) {
                applyPendingDraftSelection()
            }
            Button("Cancel", role: .cancel) {
                pendingDraftSelection = nil
            }
        } message: {
            Text("The current draft has changes that have not been published to Markdown.")
        }
        .alert(
            "Editorial Draft",
            isPresented: Binding(
                get: { draftLibraryError != nil },
                set: { if !$0 { draftLibraryError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { draftLibraryError = nil }
        } message: {
            Text(draftLibraryError ?? "The Markdown draft could not be opened.")
        }
    }

    private var selectedSection: EditorialDeskSection? {
        guard let selectedSectionID else { return nil }
        return settings.editorialDeskCatalog.sections.first { $0.id == selectedSectionID }
    }

    private var selectedType: EditorialDeskType? {
        guard let selectedTypeID else { return nil }
        return settings.editorialDeskCatalog.types.first { $0.id == selectedTypeID }
    }

    private var currentDraftMetadata: EditorialDeskMetadata {
        EditorialDeskMetadata(
            section: selectedSection,
            type: selectedType,
            date: selectedDate
        )
    }

    private var selectedDraftName: String {
        selectedDraftPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "New Draft"
    }

    private var hasUnsavedDraftChanges: Bool {
        viewModel.makeDraftSnapshot().revision != savedDraftRevision
            || currentDraftMetadata != savedDraftMetadata
    }

    /// Publishes one immutable snapshot. Existing selected Markdown is updated
    /// atomically; a new draft receives a collision-free workspace filename.
    private func publishDraft() {
        guard viewModel.hasDocument, !isPublishing else { return }

        publishError = nil
        let request = EditorialPublicationRequest(
            draft: viewModel.makeDraftSnapshot(),
            draftID: activeDraftID,
            targetRelativePath: selectedDraftPath,
            workspaceRoot: workspaceRoot,
            metadata: currentDraftMetadata
        )

        Task { @MainActor in
            applyPublicationAttempt(await publicationCoordinator.publish(request))
        }
    }

    private func applyPublicationAttempt(_ attempt: EditorialPublicationAttempt) {
        switch attempt {
        case .completed:
            publishError = nil
            dismiss()
        case .failed(let message):
            publishError = message
        case .ignored:
            break
        }
    }

    /// A destructive switch remains explicit, matching document-based macOS
    /// workflows while keeping routine selection to one menu action.
    private func requestDraftSelection(_ selection: PendingDraftSelection) {
        guard hasUnsavedDraftChanges, viewModel.hasDocument else {
            performDraftSelection(selection)
            return
        }
        pendingDraftSelection = selection
    }

    private func applyPendingDraftSelection() {
        guard let pendingDraftSelection else { return }
        self.pendingDraftSelection = nil
        performDraftSelection(pendingDraftSelection)
    }

    private func performDraftSelection(_ selection: PendingDraftSelection) {
        switch selection {
        case .newDraft:
            beginNewDraft()
        case .existing(let relativePath):
            Task { @MainActor in
                await openDraft(relativePath: relativePath)
            }
        case .dismiss:
            dismiss()
        }
    }

    private func beginNewDraft() {
        viewModel.loadDraft(EditorialDraft())
        selectedDraftPath = nil
        activeDraftID = UUID()
        selectedSectionID = nil
        selectedTypeID = nil
        selectedDate = nil
        savedDraftRevision = viewModel.makeDraftSnapshot().revision
        savedDraftMetadata = .empty
    }

    private func openDraft(relativePath: String) async {
        do {
            let file = try await dependencies.draftLibrary.load(
                relativePath: relativePath,
                workspaceRoot: workspaceRoot
            )
            viewModel.loadDraft(file.draft)
            selectedDraftPath = file.descriptor.relativePath
            activeDraftID = file.draftID ?? UUID()
            selectedSectionID = file.metadata.section.flatMap { loaded in
                settings.editorialDeskCatalog.sections.first { $0.name == loaded.name }?.id
            }
            selectedTypeID = file.metadata.type.flatMap { loaded in
                settings.editorialDeskCatalog.types.first { $0.name == loaded.name }?.id
            }
            selectedDate = file.metadata.date
            if let selectedDate {
                datePickerDate = selectedDate
            }
            savedDraftRevision = viewModel.makeDraftSnapshot().revision
            savedDraftMetadata = currentDraftMetadata
        } catch {
            draftLibraryError = error.localizedDescription
        }
    }

    private func refreshDraftLibrary() async {
        isLoadingDrafts = true
        defer { isLoadingDrafts = false }
        do {
            draftDescriptors = try await dependencies.draftLibrary.list(
                workspaceRoot: workspaceRoot
            )
        } catch {
            draftLibraryError = error.localizedDescription
        }
    }

}
