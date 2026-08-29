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

    private let workspaceRoot: String
    private let dependencies: EditorialDeskDependencies

    private var publicationPhase: EditorialPublicationPhase {
        publicationCoordinator.phase
    }

    private var publicationReceipt: EditorialPublication? {
        publicationCoordinator.receipt
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
                canonicalHandoff: dependencies.canonicalHandoff
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
                onRedo: { viewModel.redoDraft() }
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
                publicationPhase: publicationPhase,
                publicationReceipt: publicationReceipt,
                isPublishing: isPublishing,
                onDismiss: { dismiss() },
                onPublish: { publishDraft() },
                onRetryHandoff: { retryCanonicalHandoff() }
            )
        }
        .frame(minWidth: 1120, idealWidth: 1240, minHeight: 700, idealHeight: 820)
        .background(Color(nsColor: .windowBackgroundColor))
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
            if publicationPhase == .handoffFailed {
                Button("Retry handoff") {
                    retryCanonicalHandoff()
                }
            }
            Button("OK", role: .cancel) { publishError = nil }
        } message: {
            Text(publishError ?? "The draft could not be published.")
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

    /// Starts the write phase with immutable inputs. A failed handoff retains
    /// the resulting receipt and canonical request so retry never writes twice.
    private func publishDraft() {
        guard viewModel.hasDocument,
              !isPublishing,
              publicationPhase != .handoffFailed else { return }

        publishError = nil
        let request = EditorialPublicationRequest(
            draft: viewModel.makeDraftSnapshot(),
            workspaceRoot: workspaceRoot,
            sources: viewModel.selectedSources,
            metadata: EditorialDeskMetadata(
                section: selectedSection,
                type: selectedType,
                date: selectedDate
            )
        )

        Task { @MainActor in
            applyPublicationAttempt(await publicationCoordinator.publish(request))
        }
    }

    /// Retries only the second publication phase. The coordinator retains the
    /// receipt and handoff request, so this path never writes another file.
    private func retryCanonicalHandoff() {
        guard publicationPhase == .handoffFailed else { return }
        publishError = nil
        Task { @MainActor in
            applyPublicationAttempt(await publicationCoordinator.retryHandoff())
        }
    }

    private func applyPublicationAttempt(_ attempt: EditorialPublicationAttempt) {
        switch attempt {
        case .completed:
            publishError = nil
            dismiss()
        case .handoffFailed(_, _, let message), .failed(let message):
            publishError = message
        case .ignored:
            break
        }
    }

}
