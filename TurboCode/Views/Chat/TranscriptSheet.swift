import SwiftUI

/// Document-modal inspector for the active conversation's semantic transcript.
/// Selection changes only the model context projection; the visible timeline
/// and canonical persisted transcript remain available for review and branching.
struct TranscriptSheet: View {
    private enum DisplayMode: String, CaseIterable, Identifiable {
        case conversation = "Conversation"
        case entries = "Entries"

        var id: Self { self }
    }

    let threadID: String

    @Environment(ChatStore.self) private var chatStore
    @Environment(\.dismiss) private var dismiss
    @State private var presentation: TranscriptContextPresentation?
    @State private var displayMode: DisplayMode = .conversation
    @State private var selectedItemID: String?
    @State private var initialExcludedGroupIDs: Set<String> = []
    @State private var excludedGroupIDs: Set<String> = []
    @State private var isApplying = false
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 860, idealWidth: 940, minHeight: 600, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: threadID) {
            guard chatStore.activeThreadId == threadID else {
                dismiss()
                return
            }
            await reload()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "text.document")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Transcript")
                    .font(.title2.weight(.semibold))
                if let presentation {
                    Text(summary(for: presentation))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Loading conversation history…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("Transcript view", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        if let presentation {
            if presentation.hasTranscript {
                HSplitView {
                    transcriptList(presentation)
                        .frame(minWidth: 480, maxWidth: .infinity)
                        .layoutPriority(1)
                    inspector(presentation)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                }
            } else {
                ContentUnavailableView(
                    "Transcript Unavailable",
                    systemImage: "text.document",
                    description: Text(
                        "This session does not expose an editable semantic transcript. "
                            + "Its visible conversation remains available in the chat."
                    )
                )
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func transcriptList(
        _ presentation: TranscriptContextPresentation
    ) -> some View {
        let items = displayMode == .conversation
            ? presentation.conversationItems
            : presentation.entryItems

        return List(selection: $selectedItemID) {
            ForEach(items) { item in
                TranscriptSheetRow(
                    item: item,
                    isExcluded: item.groupID.map(excludedGroupIDs.contains) ?? false,
                    showsContextToggle: item.kind == .toolExchange || item.kind == .toolCall,
                    onToggle: {
                        guard let groupID = item.groupID else { return }
                        if excludedGroupIDs.contains(groupID) {
                            excludedGroupIDs.remove(groupID)
                        } else {
                            excludedGroupIDs.insert(groupID)
                        }
                    }
                )
                .tag(item.id)
            }
        }
        .listStyle(.inset)
    }

    private func inspector(
        _ presentation: TranscriptContextPresentation
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let group = selectedGroup(in: presentation) {
                    Label("Context Selection", systemImage: "checklist")
                        .font(.headline)

                    inspectorValue("Selection", value: group.title)
                    inspectorValue(
                        "Tools",
                        value: group.toolNames.joined(separator: ", ")
                    )
                    inspectorValue(
                        "Estimated size",
                        value: formattedTokens(group.estimatedTokens)
                    )

                    Toggle(
                        "Exclude from model context",
                        isOn: exclusionBinding(for: group.id)
                    )
                    .toggleStyle(.switch)
                } else if let item = selectedItem(in: presentation) {
                    Label(item.title, systemImage: symbol(for: item.kind))
                        .font(.headline)
                    Text(item.detail.isEmpty ? "No textual content." : item.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    inspectorValue(
                        "Estimated size",
                        value: formattedTokens(item.estimatedTokens)
                    )
                } else {
                    Label("Context Projection", systemImage: "rectangle.stack")
                        .font(.headline)
                    Text(
                        "Select a transcript entry to inspect it. Only completed "
                            + "tool exchanges can be excluded."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Divider()

                inspectorValue(
                    "Context reduction",
                    value: formattedTokens(excludedTokenEstimate(in: presentation))
                )

                Label {
                    Text(
                        "The canonical transcript and visible conversation are preserved. "
                            + "Provider cache state after the first changed entry may be rebuilt."
                    )
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let localError {
                    Label(localError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Changes affect future model requests only.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(actionTitle) {
                Task { await applyChanges() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                presentation?.hasTranscript != true
                    || excludedGroupIDs == initialExcludedGroupIDs
                    || isApplying
                    || chatStore.busy
            )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var actionTitle: String {
        let added = excludedGroupIDs.subtracting(initialExcludedGroupIDs)
        let removed = initialExcludedGroupIDs.subtracting(excludedGroupIDs)
        if !added.isEmpty, removed.isEmpty { return "Exclude from Context" }
        if added.isEmpty, !removed.isEmpty { return "Include in Context" }
        return "Apply Context Changes"
    }

    private func reload() async {
        let value = await chatStore.transcriptContextPresentation()
        guard !Task.isCancelled, chatStore.activeThreadId == threadID else { return }
        presentation = value
        initialExcludedGroupIDs = value.excludedGroupIDs
        excludedGroupIDs = value.excludedGroupIDs
        selectedItemID = value.conversationItems.first?.id
        localError = nil
    }

    private func applyChanges() async {
        isApplying = true
        localError = nil
        let applied = await chatStore.applyTranscriptContextSelection(excludedGroupIDs)
        isApplying = false
        guard applied else {
            localError = "The context projection could not be applied."
            return
        }
        await reload()
    }

    private func selectedItem(
        in presentation: TranscriptContextPresentation
    ) -> TranscriptContextItem? {
        let allItems = presentation.conversationItems + presentation.entryItems
        return allItems.first { $0.id == selectedItemID }
    }

    private func selectedGroup(
        in presentation: TranscriptContextPresentation
    ) -> TranscriptToolExchangeGroup? {
        guard let item = selectedItem(in: presentation),
              let groupID = item.groupID else { return nil }
        return presentation.groups.first { $0.id == groupID }
    }

    private func exclusionBinding(for groupID: String) -> Binding<Bool> {
        Binding(
            get: { excludedGroupIDs.contains(groupID) },
            set: { excluded in
                if excluded {
                    excludedGroupIDs.insert(groupID)
                } else {
                    excludedGroupIDs.remove(groupID)
                }
            }
        )
    }

    private func excludedTokenEstimate(
        in presentation: TranscriptContextPresentation
    ) -> Int {
        presentation.groups
            .filter { excludedGroupIDs.contains($0.id) }
            .reduce(0) { $0 + $1.estimatedTokens }
    }

    private func summary(for presentation: TranscriptContextPresentation) -> String {
        let count = presentation.entryItems.count
        return "\(count) entries · approximately "
            + formattedTokens(presentation.totalEstimatedTokens)
    }

    private func inspectorValue(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
        }
    }

    private func formattedTokens(_ count: Int) -> String {
        count.formatted(.number) + (count == 1 ? " token" : " tokens")
    }

    private func symbol(for kind: TranscriptContextItem.Kind) -> String {
        switch kind {
        case .instructions: "gearshape"
        case .user: "person.crop.circle"
        case .assistant: "sparkles"
        case .reasoning: "brain"
        case .toolExchange: "wrench.and.screwdriver"
        case .toolCall: "arrow.up.forward.app"
        case .toolOutput: "arrow.down.forward.app"
        case .unknown: "doc.text"
        }
    }
}

private struct TranscriptSheetRow: View {
    let item: TranscriptContextItem
    let isExcluded: Bool
    let showsContextToggle: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(item.kind == .toolExchange ? Color.accentColor : .secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(item.estimatedTokens.formatted(.number) + " estimated tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if showsContextToggle {
                Button(action: onToggle) {
                    Image(systemName: isExcluded ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isExcluded ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isExcluded ? "Include in model context" : "Exclude from model context")
                .accessibilityLabel(
                    isExcluded ? "Include in model context" : "Exclude from model context"
                )
            } else if item.groupID != nil, isExcluded {
                Text("Excluded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .opacity(isExcluded ? 0.7 : 1)
    }

    private var symbol: String {
        switch item.kind {
        case .instructions: "gearshape"
        case .user: "person.crop.circle"
        case .assistant: "sparkles"
        case .reasoning: "brain"
        case .toolExchange: "wrench.and.screwdriver"
        case .toolCall: "arrow.up.forward.app"
        case .toolOutput: "arrow.down.forward.app"
        case .unknown: "doc.text"
        }
    }
}
