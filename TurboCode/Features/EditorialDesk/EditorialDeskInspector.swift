import SwiftUI

/// Inspector tabs are a presentation concern and remain independent of the
/// editor's draft semantics.
enum EditorialDeskInspectorTab: String, CaseIterable, Identifiable {
    case info = "Info"
    case sources = "Sources"
    case notes = "Notes"

    var id: Self { self }
}

/// Displays source provenance and editorial review without owning any desk
/// state. All mutations are narrow ViewModel commands or bindings.
struct EditorialDeskInspector: View {
    @Bindable var viewModel: EditorialDeskViewModel
    @Binding var selectedTab: EditorialDeskInspectorTab
    @Binding var sourceImporterPresented: Bool
    @Binding var renameSourceID: UUID?
    @Binding var renameSourceText: String
    @Binding var selectedDate: Date?
    @Binding var datePickerDate: Date
    @Binding var datePickerPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(EditorialDeskInspectorTab.allCases) { tab in
                    Button {
                        selectedTab = tab
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
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(
                            selectedTab == tab ? Color.accentColor : Color.secondary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.08)
                                : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Editorial inspector section")

            Divider()

            ScrollView {
                switch selectedTab {
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
                dateInspectorField
            } else {
                emptyInspectorState(
                    title: "Your desk is ready",
                    message: "Write an article here, or bring one in from a tab above."
                )
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Ground truth")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("\(viewModel.selectedSources.count) of \(viewModel.sources.count) sources selected")
                    .font(.callout.weight(.semibold))
                if viewModel.sources.isEmpty {
                    Text("No ground-truth sources yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.sources) { source in
                        sourceCard(source)
                    }
                }
                Button {
                    sourceImporterPresented = true
                } label: {
                    Label("Add source", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
    }

    private var sourcesInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ground-truth sources")
                .font(.headline)
            Text("\(viewModel.selectedSources.count) of \(viewModel.sources.count) selected for the next operation.")
                .font(.callout.weight(.semibold))
            Text("The editorial assistant will compare the draft against these sources and flag every discrepancy.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let importError = viewModel.importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if viewModel.sources.isEmpty {
                Text("No sources added yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.sources) { source in
                    sourceCard(source)
                }
            }
            Button("Add source") {
                sourceImporterPresented = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var notesInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Editorial review")
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
                    .textSelection(.enabled)
            } else if let result = viewModel.result {
                Text(result.summary)
                    .font(.callout)
                    .textSelection(.enabled)
                if result.findings.isEmpty {
                    Label("No discrepancies found", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                } else {
                    Text("\(result.findings.count) finding(s) to review")
                        .font(.callout.weight(.semibold))
                    ForEach(result.findings) { finding in
                        findingReviewCard(finding)
                    }
                }

                if let revision = viewModel.revision {
                    revisionReview(revision)
                } else if viewModel.lastAction?.isDiagnostic == true
                    || (result.revisedDraft == nil && result.revisedDocument == nil) {
                    Label("No draft revision proposed", systemImage: "lock.doc")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label("The proposed draft matches the current draft", systemImage: "equal.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

    private func findingReviewCard(_ finding: EditorialFinding) -> some View {
        let status = viewModel.findingStatus(for: finding.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(finding.sourceName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(finding.severity.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(findingColor(finding.severity))
                Text(status.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(findingStatusColor(status))
            }
            Text(finding.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !finding.documentExcerpt.isEmpty {
                Text("Draft: \"\(finding.documentExcerpt)\"")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !finding.sourceExcerpt.isEmpty {
                Text("Source: \"\(finding.sourceExcerpt)\"")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Acknowledge") {
                    viewModel.acknowledgeFinding(finding.id)
                }
                .buttonStyle(.bordered)
                .disabled(status != .open)
                Button("Dismiss") {
                    viewModel.dismissFinding(finding.id)
                }
                .buttonStyle(.bordered)
                .disabled(status != .open)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func revisionReview(_ revision: EditorialRevision) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Proposed changes")
                    .font(.callout.weight(.semibold))
                Spacer()
                if let status = viewModel.revisionStatus {
                    Text(status.rawValue.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(revisionStatusColor(status))
                }
            }

            ForEach(revision.changes) { change in
                revisionChangeCard(change)
            }

            HStack(spacing: 8) {
                Button("Apply all") {
                    viewModel.applyAllRevision()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canApplyRevision)
                Button("Reject all") {
                    viewModel.rejectRevision()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canApplyRevision)
                Button("Undo") {
                    viewModel.undoDraft()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canUndoDraft)
            }
        }
    }

    private func revisionChangeCard(_ change: EditorialRevisionChange) -> some View {
        let status = viewModel.revisionStatus(for: change.field)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(change.field.label)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(status.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(revisionChangeStatusColor(status))
            }
            diffValue(label: "Before", value: change.before)
            diffValue(label: "After", value: change.after)
            HStack(spacing: 8) {
                Button("Apply") {
                    viewModel.applyRevision(for: change.field)
                }
                .buttonStyle(.bordered)
                .disabled(status != .pending)
                Button("Reject") {
                    viewModel.rejectRevision(for: change.field)
                }
                .buttonStyle(.bordered)
                .disabled(status != .pending)
            }
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    private func diffValue(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "Empty" : value)
                .font(.caption)
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
        }
    }

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
        .help("Choose publication date")
        .accessibilityLabel(selectedDate.map { "Publication date \(displayDate($0))" } ?? "Add publication date")
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
    }

    private func emptyInspectorState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 16, weight: .medium, design: .serif))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceCard(_ title: String, subtitle: String, mark: String, color: Color, preview: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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

            if let preview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5) }
    }

    private func sourceCard(_ source: EditorialSource) -> some View {
        let isSelected = viewModel.selectedSourceIDs.contains(source.id)
        return sourceCard(
            source.name,
            subtitle: "\(source.origin.label) · \(byteCountDescription(source.byteCount)) · \(isSelected ? "selected" : "excluded")",
            mark: String(source.name.prefix(3)).uppercased(),
            color: .green,
            preview: source.preview
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.name), \(source.origin.label)")
        .accessibilityValue(isSelected ? "Included as ground truth" : "Excluded from ground truth")
        .accessibilityHint("Activate to toggle ground-truth selection.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
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

    private func byteCountDescription(_ byteCount: Int) -> String {
        if byteCount < 1_024 { return "\(byteCount) B" }
        if byteCount < 1_048_576 { return "\(byteCount / 1_024) KB" }
        return String(format: "%.1f MB", Double(byteCount) / 1_048_576)
    }

    private func displayDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func findingColor(_ severity: EditorialFinding.Severity) -> Color {
        switch severity {
        case .note: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }

    private func findingStatusColor(_ status: EditorialFindingStatus) -> Color {
        switch status {
        case .open: .orange
        case .acknowledged: .green
        case .dismissed: .secondary
        }
    }

    private func revisionChangeStatusColor(_ status: EditorialRevisionChangeStatus) -> Color {
        switch status {
        case .pending: .orange
        case .applied: .green
        case .rejected: .secondary
        }
    }

    private func revisionStatusColor(_ status: EditorialRevisionStatus) -> Color {
        switch status {
        case .pending, .partial: .orange
        case .applied: .green
        case .rejected: .secondary
        }
    }
}
