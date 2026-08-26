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
    @State private var selectedInspectorTab: InspectorTab = .info
    @State private var selectedSectionID: UUID?
    @State private var selectedTypeID: UUID?
    @State private var selectedDate: Date?
    @State private var datePickerDate = Date()
    @State private var datePickerPresented = false
    @State private var actionMenuPresented = false
    @State private var selectedLine = 4
    @State private var sourceImporterPresented = false
    @State private var renameSourceID: UUID?
    @State private var renameSourceText = ""
    @State private var isPublishing = false
    @State private var publishError: String?

    enum InspectorTab: String, CaseIterable, Identifiable {
        case info = "Info"
        case sources = "Sources"
        case notes = "Notes"

        var id: Self { self }
    }

    private let workspaceRoot: String
    private let publishToCanonicalSession: @MainActor (String, String, [EditorialSource], EditorialDeskMetadata) async -> Void

    init(
        workspaceRoot: String,
        modelClient: (any EditorialModelClient)? = nil,
        publishToCanonicalSession: @escaping @MainActor (String, String, [EditorialSource], EditorialDeskMetadata) async -> Void = { _, _, _, _ in }
    ) {
        self.workspaceRoot = workspaceRoot
        self.publishToCanonicalSession = publishToCanonicalSession
        let viewModel = EditorialDeskViewModel(
            workspaceRoot: workspaceRoot,
            modelClient: modelClient
        )
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            topToolbar
            metadataBar
            Divider()

            HStack(spacing: 0) {
                articleCanvas
                inspector
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)

            Divider()
            footer
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
                viewModel.importFiles(urls)
                selectedInspectorTab = .sources
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
    }

    private var titleBar: some View {
        ZStack {
            Text("Editorial Desk")
                .font(.system(size: 14, weight: .semibold))

            HStack {
                Spacer()
                Button {} label: {
                    Image(systemName: "rectangle.3.group")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Toggle editorial workspace layout")
            }
        }
        .frame(height: 38)
        .padding(.horizontal, 18)
        .background(.bar)
    }

    private var topToolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(EditorialDeskTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                        viewModel.selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(
                                selectedTab == tab ? Color.accentColor : Color.secondary
                            )
                            .padding(.horizontal, 15)
                            .frame(height: 30)
                            .background(
                                selectedTab == tab
                                    ? Color(nsColor: .textBackgroundColor)
                                    : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.7), in: Capsule())

            Divider().frame(height: 18)

            toolbarButton("arrow.uturn.backward", help: "Undo") {
                viewModel.undoDraft()
            }
            toolbarButton("arrow.uturn.forward", help: "Redo") {
                viewModel.redoDraft()
            }
            toolbarButton("list.bullet", help: "Show document outline")

            Spacer()

            Menu {
                Button("Editorial assistant active") {}
                Button("Pause assistant") {}
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("Editorial assistant active")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
            }
            .menuStyle(.borderlessButton)

            toolbarButton("sidebar.right", help: "Show editorial inspector")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func toolbarButton(
        _ icon: String,
        help: String,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var metadataBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // The catalog menus provide behavior only; the custom capsule
                // owns both the visible chrome and its dynamic text width.
                Menu {
                    if settings.editorialDeskCatalog.sections.isEmpty {
                        Text("Configure sections in Settings")
                    } else {
                        ForEach(settings.editorialDeskCatalog.sections) { option in
                            Button {
                                selectedSectionID = option.id
                            } label: {
                                Label(option.name, systemImage: option.systemImage)
                            }
                        }
                    }
                } label: {
                    metadataChip(
                        icon: selectedSection?.systemImage ?? "tag",
                        title: "Section",
                        value: selectedSection?.name ?? "",
                        isPlaceholder: selectedSection == nil
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(settings.editorialDeskCatalog.sections.isEmpty)

                Menu {
                    if settings.editorialDeskCatalog.types.isEmpty {
                        Text("Configure article types in Settings")
                    } else {
                        ForEach(settings.editorialDeskCatalog.types) { option in
                            Button {
                                selectedTypeID = option.id
                            } label: {
                                Label(option.name, systemImage: option.systemImage)
                            }
                        }
                    }
                } label: {
                    metadataChip(
                        icon: selectedType?.systemImage ?? "bolt",
                        // Once selected, the type name replaces the generic
                        // placeholder exactly like the editorial reference.
                        title: selectedType == nil ? "Type" : "",
                        value: selectedType?.name ?? "",
                        tint: selectedType.map { editorialColor($0.colorHex) } ?? .secondary,
                        isPlaceholder: selectedType == nil
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(settings.editorialDeskCatalog.types.isEmpty)

                if viewModel.hasDocument {
                    metadataChip(icon: "textformat", title: "Style", value: "Choose style")
                }
                if !viewModel.sources.isEmpty {
                    metadataChip(
                        icon: "checkmark.shield",
                        title: "",
                        value: "\(viewModel.sources.count) sources",
                        tint: .green
                    )
                }
                if !viewModel.hasDocument,
                   viewModel.sources.isEmpty,
                   selectedSection == nil,
                   selectedType == nil {
                    Text("Start with a document or a source")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Date belongs to the inspector's document metadata, alongside author
    /// and location, rather than to the taxonomy controls in the top bar.
    private var dateInspectorField: some View {
        Button {
            datePickerDate = selectedDate ?? Date()
            datePickerPresented = true
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("Date")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Text(selectedDate.map(displayDate) ?? "Add date")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "calendar")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $datePickerPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Publication date")
                    .font(.headline)

                DatePicker(
                    "Date",
                    selection: $datePickerDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()

                Divider()

                HStack {
                    if selectedDate != nil {
                        Button("Clear") {
                            selectedDate = nil
                            datePickerPresented = false
                        }
                    }
                    Spacer()
                    Button("Cancel") {
                        datePickerPresented = false
                    }
                    Button("Done") {
                        selectedDate = datePickerDate
                        datePickerPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 300)
        }
        .help("Choose publication date")
    }

    private func displayDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private var selectedSection: EditorialDeskSection? {
        guard let id = selectedSectionID else { return nil }
        return settings.editorialDeskCatalog.sections.first { $0.id == id }
    }

    private var selectedType: EditorialDeskType? {
        guard let id = selectedTypeID else { return nil }
        return settings.editorialDeskCatalog.types.first { $0.id == id }
    }

    private func editorialColor(_ hex: String) -> Color {
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt64(normalized, radix: 16) else { return .accentColor }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private func metadataChip(
        icon: String,
        title: String,
        value: String,
        tint: Color = .secondary,
        isPlaceholder: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(isPlaceholder ? Color.secondary : tint)
            // Borderless macOS menus may collapse sibling Text views in their
            // label. A single composed Text keeps the selected catalog value.
            metadataChipText(title: title, value: value, tint: tint)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 30)
        // A menu can otherwise retain the placeholder's intrinsic width and
        // clip a longer catalog value selected later in the same presentation.
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
    }

    private func metadataChipText(
        title: String,
        value: String,
        tint: Color
    ) -> Text {
        let valueColor = tint == Color.secondary ? Color.primary : tint
        if title.isEmpty {
            return Text(value).foregroundColor(valueColor)
        }
        if value.isEmpty {
            return Text("\(title):").foregroundColor(.secondary)
        }
        return Text("\(title): ").foregroundColor(.secondary)
            + Text(value).foregroundColor(valueColor)
    }

    private var articleCanvas: some View {
        GeometryReader { _ in
            VStack(alignment: .leading, spacing: 0) {
                articleHeader
                Divider()

                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 0) {
                        if !viewModel.documentContent.isEmpty {
                            lineNumberGutter
                        }

                        ZStack(alignment: .topLeading) {
                            EditorialCanvasTextView(
                                text: Binding(
                                    get: { viewModel.documentContent },
                                    set: { viewModel.updateBody($0) }
                                )
                            )

                            if viewModel.documentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                emptyDocumentPrompt
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.vertical, 14)

                    if selectedTab != .write {
                        intakePanel
                            .padding(.horizontal, 28)
                            .padding(.top, 16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }

                    if viewModel.hasDocument {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                actionMenuPresented.toggle()
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 28, height: 28)
                                .background(.background, in: Circle())
                                .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                                .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .help("Open editorial actions")
                        .padding(.leading, 16)
                        .padding(.top, 124)

                        if actionMenuPresented {
                            editorialActionMenu
                                .transition(.scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity))
                                .padding(.top, 124)
                                .padding(.trailing, 20)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var intakePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(selectedTab.rawValue, systemImage: selectedTab.systemImage)
                    .font(.headline)
                Spacer()
                Button {
                    selectedTab = .write
                    viewModel.selectedTab = .write
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close intake panel")
            }

            Text("Add material to the desk as a draft or as a ground-truth source.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField(
                "Source name (optional)",
                text: Binding(
                    get: { viewModel.intakeName },
                    set: { viewModel.intakeName = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)

            TextEditor(
                text: Binding(
                    get: { viewModel.intakeText },
                    set: { viewModel.intakeText = $0 }
                )
            )
            .font(.system(size: 13))
            .frame(minHeight: 150)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }

            HStack {
                Button("Use as document") {
                    viewModel.useIntakeAsDocument()
                    selectedTab = .write
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canCommitIntake)

                Button("Add as source") {
                    viewModel.addIntakeAsSource()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canCommitIntake)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.13), radius: 12, y: 5)
        .frame(maxWidth: 560)
    }

    private var articleHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField(
                "Title",
                text: Binding(
                    get: { viewModel.documentTitle },
                    set: { viewModel.updateTitle($0) }
                )
            )
                .font(.system(size: 25, weight: .medium, design: .serif))
                .textFieldStyle(.plain)

            TextField(
                "Subtitle (deck)",
                text: Binding(
                    get: { viewModel.documentDeck },
                    set: { viewModel.updateDeck($0) }
                )
            )
            .font(.system(size: 14))
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
    }

    private var lineNumberGutter: some View {
        let lineCount = max(
            1,
            viewModel.documentContent.components(separatedBy: "\n").count
        )
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<lineCount, id: \.self) { index in
                Text("\(index + 1)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(height: 23, alignment: .top)
            }
        }
        .frame(width: 52, alignment: .trailing)
        .padding(.trailing, 18)
        .padding(.top, 11)
    }

    private var emptyDocumentPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "text.cursor")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("Start writing")
                .font(.system(size: 18, weight: .medium, design: .serif))
            Text("Write directly here, or choose Paste, From Notes, or From Transcript above.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.leading, 12)
    }

    private func emptyInspectorState(
        title: String,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 16, weight: .medium, design: .serif))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var editorialActionMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionButton("Verify facts", icon: "checkmark.seal")
            actionButton("Make neutral", icon: "circle.lefthalf.filled")
            actionButton("Tighten the lead", icon: "diamond")
            actionButton("Check citations", icon: "list.bullet.indent")
            actionButton("Desk summary", icon: "list.bullet.rectangle")
        }
        .padding(6)
        .frame(width: 164)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func actionButton(_ title: String, icon: String) -> some View {
        Button {
            guard let action = EditorialAction(rawValue: title) else { return }
            actionMenuPresented = false
            selectedInspectorTab = .notes
            viewModel.run(action: action, document: editorialDocument)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .frame(height: 28)
        }
        .buttonStyle(.plain)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(InspectorTab.allCases) { tab in
                    Button {
                        selectedInspectorTab = tab
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.rawValue)
                            if tab == .sources {
                                Text("\(viewModel.sources.count)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        .font(.system(size: 12, weight: selectedInspectorTab == tab ? .semibold : .regular))
                        .foregroundStyle(
                            selectedInspectorTab == tab
                                ? Color.accentColor
                                : Color.secondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            selectedInspectorTab == tab
                                ? Color.accentColor.opacity(0.08)
                                : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)

            Divider()

            ScrollView {
                switch selectedInspectorTab {
                case .info:
                    infoInspector
                case .sources:
                    sourcesInspector
                case .notes:
                    notesInspector
                }
            }
        }
        .frame(width: 286)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var infoInspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            if viewModel.hasDocument {
                inspectorField("Author", value: "Add author", disclosure: true)
                dateInspectorField
                inspectorField("Location", value: "Add location", icon: "mappin")
            } else {
                emptyInspectorState(
                    title: "Your desk is ready",
                    message: "Write an article here, or bring one in from a tab above."
                )
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Sources")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if viewModel.sources.isEmpty {
                    Text("No ground-truth sources yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.sources) { source in
                        sourceCard(source)
                    }
                }

                Button { sourceImporterPresented = true } label: {
                    Label("Add source", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if viewModel.hasDocument {
                Divider()
                inspectorField("Legal sensitivity", value: "Set sensitivity", tint: .orange, disclosure: true)
                inspectorField("SEO title", value: "Generate suggestion", icon: "doc.on.doc")
            }
        }
        .padding(16)
    }

    private var sourcesInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ground-truth sources")
                .font(.headline)
            Text("The editorial assistant will compare the draft against these sources and flag every discrepancy.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let importError = viewModel.importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(viewModel.sources) { source in
                sourceCard(source)
            }
            Button("Add source") { sourceImporterPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var notesInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Editorial notes")
                .font(.headline)
            if viewModel.isRunning {
                ProgressView("Running editorial check…")
                    .controlSize(.small)
                Button(viewModel.isCancelling ? "Stopping…" : "Stop") {
                    viewModel.cancelOperation()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isCancelling)
            } else if let modelError = viewModel.modelError {
                Label(modelError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if let result = viewModel.result {
                Text(result.summary)
                    .font(.callout)
                if result.findings.isEmpty {
                    Label("No discrepancies found", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                } else {
                    Text("\(result.findings.count) finding(s) to review")
                        .font(.callout.weight(.semibold))
                    ForEach(result.findings.prefix(4)) { finding in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(finding.sourceName)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(finding.severity.rawValue.capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(findingColor(finding.severity))
                            }
                            Text(finding.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !finding.documentExcerpt.isEmpty {
                                Text("Draft: \"\(finding.documentExcerpt)\"")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !finding.sourceExcerpt.isEmpty {
                                Text("Source: \"\(finding.sourceExcerpt)\"")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if result.revisedDocument != nil {
                    Button("Apply revised draft") {
                        viewModel.applyRevision()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isRunning)

                    Button("Undo last revision") {
                        viewModel.undoDraft()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canUndoDraft)
                }
            } else {
                Text(viewModel.hasDocument
                    ? "Run an editorial action to see findings here."
                    : "Add a document first to run an editorial action.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private func findingColor(_ severity: EditorialFinding.Severity) -> Color {
        switch severity {
        case .note: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }

    private func inspectorField(
        _ label: String,
        value: String,
        icon: String? = nil,
        tint: Color = .primary,
        disclosure: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 7) {
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(2)
                Spacer()
                if let icon {
                    Image(systemName: icon).foregroundStyle(.secondary)
                }
                if disclosure {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sourceCard(
        _ title: String,
        subtitle: String,
        mark: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Text(mark)
                .font(.system(size: mark.count > 2 ? 8 : 14, weight: .bold, design: .serif))
                .foregroundStyle(color == .black ? Color.primary : Color.white)
                .frame(width: 27, height: 27)
                .background(
                    color == .black ? Color(nsColor: .textBackgroundColor) : color,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5) }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Circle().fill(.green).frame(width: 8, height: 8)
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5) }
    }

    private func sourceCard(_ source: EditorialSource) -> some View {
        let isSelected = viewModel.selectedSourceIDs.contains(source.id)
        return sourceCard(
            source.name,
            subtitle: "\(source.origin.label) · verified",
            mark: String(source.name.prefix(3)).uppercased(),
            color: .green
        )
        .opacity(isSelected ? 1 : 0.55)
        .overlay(alignment: .trailing) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.green : Color.secondary)
                .padding(.trailing, 9)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.toggleSource(source.id)
        }
        .contextMenu {
            Button(isSelected ? "Exclude from ground truth" : "Use as ground truth") {
                viewModel.toggleSource(source.id)
            }
            Button("Rename source") {
                renameSourceID = source.id
                renameSourceText = source.name
            }
            Divider()
            Button("Remove source", role: .destructive) {
                viewModel.removeSource(source.id)
            }
        }
    }

    private var footer: some View {
        let wordCount = viewModel.draftText
            .split(whereSeparator: { $0.isWhitespace })
            .count
        return HStack(spacing: 14) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            footerStat("Words", value: "\(wordCount)")
            footerDivider
            footerStat("Reading", value: wordCount == 0 ? "—" : "\(max(1, wordCount / 210)) min")
            footerDivider
            footerStat("Sources", value: "\(viewModel.sources.count)")
            footerDivider
            Label(viewModel.hasDocument ? "Draft ready" : "Empty desk", systemImage: "checkmark")

            Spacer()

            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)

            Menu {
                Button {
                    publishDraft()
                } label: {
                    if isPublishing {
                        Label("Publishing…", systemImage: "arrow.up.circle")
                    } else {
                        Label("Publish now", systemImage: "arrow.up.circle")
                    }
                }
                .disabled(isPublishing)
            } label: {
                HStack(spacing: 8) {
                    if isPublishing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isPublishing ? "Publishing…" : "Publish Draft")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.hasDocument || isPublishing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func footerStat(_ label: String, value: String) -> some View {
        Text("\(label): \(value)")
    }

    private var footerDivider: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 14)
    }

    private func publishDraft() {
        guard viewModel.hasDocument, !isPublishing else { return }
        isPublishing = true
        publishError = nil

        let document = viewModel.draftText
        let title = viewModel.documentTitle
        let sources = viewModel.selectedSources
        let metadata = EditorialDeskMetadata(
            section: selectedSection,
            type: selectedType,
            date: selectedDate
        )
        Task { @MainActor in
            do {
                let publication = try EditorialDraftPublisher.publish(
                    document: document,
                    title: title,
                    workspaceRoot: workspaceRoot,
                    metadata: metadata
                )
                await publishToCanonicalSession(
                    document,
                    publication.fileName,
                    sources,
                    metadata
                )
                isPublishing = false
                dismiss()
            } catch {
                isPublishing = false
                publishError = error.localizedDescription
            }
        }
    }

    private var editorialDocument: String {
        viewModel.draftText
    }
}

/// AppKit supplies the editable text surface while the surrounding SwiftUI
/// canvas owns the editorial chrome, gutter, empty state, and inspector.
private struct EditorialCanvasTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.usesFindPanel = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
