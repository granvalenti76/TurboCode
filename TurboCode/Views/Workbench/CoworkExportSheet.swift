import SwiftUI

// MARK: - Cowork export review

/// The only path from a Cowork session to the user's folders. Every file is
/// listed with its fate; conflicts default to Skip and show a text diff on
/// request; nothing is copied until the user presses Export.
struct CoworkExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: CoworkExportViewModel
    @State private var diff: DiffPatchReviewPresentation?
    @State private var confirmingClear = false
    @State private var showsSkipped = false

    init(presentation: CoworkExportPresentation) {
        _model = State(initialValue: CoworkExportViewModel(presentation: presentation))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 440, idealHeight: 540)
        .task { await model.refresh() }
        .sheet(item: $diff) { presentation in
            DiffPatchReviewSheet(patch: presentation.patch)
        }
        .confirmationDialog("Clear this session's deliverables?", isPresented: $confirmingClear) {
            Button("Clear Deliverables", role: .destructive) {
                Task { await model.clearDeliverables() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files in /out are deleted for this session. Files already exported to your Mac are kept.")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Export Deliverables")
                .font(.title3.weight(.semibold))
            Text(model.presentation.sessionTitle)
                .foregroundStyle(.secondary)
            HStack {
                Label {
                    Text(model.destination?.path ?? "No destination selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                }
                Spacer()
                Button(model.destination == nil ? "Choose Destination…" : "Change…") {
                    Task { await model.chooseDestination() }
                }
                .disabled(model.phase == .exporting)
            }
        }
        .padding(16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .planning:
            ProgressView("Reading deliverables…")
        case .exporting:
            ProgressView("Copying approved files…")
        case .failed(let message):
            ContentUnavailableView("Cannot Read Deliverables", systemImage: "exclamationmark.triangle", description: Text(message))
        case .finished(let report):
            reportView(report)
        case .ready:
            if model.destination == nil {
                ContentUnavailableView(
                    "Choose a Destination",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Pick the Mac folder that should receive the deliverables.")
                )
            } else if let plan = model.plan, !plan.items.isEmpty || !plan.skipped.isEmpty {
                planList(plan)
            } else {
                ContentUnavailableView(
                    "No Deliverables",
                    systemImage: "tray",
                    description: Text("The agent has not placed any files in /out for this session.")
                )
            }
        }
    }

    private func planList(_ plan: CoworkExportPlan) -> some View {
        List {
            Section {
                ForEach(plan.items) { item in
                    itemRow(item)
                }
            } header: {
                Text("\(plan.items.count) files · \(plan.totalBytes.formatted(.byteCount(style: .file)))")
            } footer: {
                if plan.exceedsLimits {
                    Toggle("This export is unusually large. Export it anyway.", isOn: $model.confirmsLargeExport)
                }
            }
            if !plan.skipped.isEmpty {
                Section {
                    DisclosureGroup("\(plan.skipped.count) not exported", isExpanded: $showsSkipped) {
                        ForEach(plan.skipped) { skip in
                            LabeledContent(skip.relativePath, value: skip.explanation)
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: CoworkExportItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.size.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch item.kind {
            case .new:
                Toggle("Export", isOn: Binding(
                    get: { model.decisions[item.id] == .copy },
                    set: { model.decisions[item.id] = $0 ? .copy : .skip }
                ))
                .labelsHidden()
                .help("New file")
            case .identical:
                Text("Identical")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .conflict:
                if item.isText {
                    Button("Diff") { showDiff(item) }
                        .controlSize(.small)
                }
                Picker("Existing file", selection: Binding(
                    get: { model.decisions[item.id] ?? .skip },
                    set: { model.decisions[item.id] = $0 }
                )) {
                    Text("Skip").tag(CoworkExportDecision.skip)
                    Text("Replace").tag(CoworkExportDecision.replace)
                    Text("Keep Both").tag(CoworkExportDecision.keepBoth)
                }
                .labelsHidden()
                .fixedSize()
                .help("A different file with this name already exists")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func reportView(_ report: CoworkExportReport) -> some View {
        List {
            Section("Copied \(report.copiedCount) of \(report.outcomes.count)") {
                ForEach(Array(report.outcomes.enumerated()), id: \.offset) { _, entry in
                    LabeledContent(entry.path) {
                        switch entry.outcome {
                        case .copied: Label("Copied", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .skipped: Text("Skipped").foregroundStyle(.secondary)
                        case .changedSinceReview: Label("Changed since review", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        case .failed(let message): Text(message).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Show in Finder") { model.showOutboxInFinder() }
            Button("Clear Deliverables…", role: .destructive) { confirmingClear = true }
                .disabled(model.phase == .exporting)
            Spacer()
            if case .finished = model.phase {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export \(model.selectedItems.count) Files") {
                    Task { await model.export() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExport)
            }
        }
        .padding(16)
    }

    private func showDiff(_ item: CoworkExportItem) {
        guard let block = model.diffBlock(for: item) else { return }
        diff = DiffPatchReviewPresentation(id: item.id, patch: block)
    }
}
