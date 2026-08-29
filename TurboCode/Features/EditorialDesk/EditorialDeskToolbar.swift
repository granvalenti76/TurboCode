import SwiftUI

/// Toolbar controls with concrete actions only. The assistant status is
/// informational; pause and outline controls stay out until they are real.
struct EditorialDeskToolbar: View {
    @Binding var selectedTab: EditorialDeskTab
    let onSelectTab: (EditorialDeskTab) -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let draftName: String
    let draftDescriptors: [EditorialDraftDescriptor]
    let selectedDraftPath: String?
    let hasUnsavedChanges: Bool
    let isLoadingDrafts: Bool
    let onNewDraft: () -> Void
    let onSelectDraft: (String) -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(EditorialDeskTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                        onSelectTab(tab)
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
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.7), in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Editorial input mode")

            Divider().frame(height: 18)

            toolbarButton("arrow.uturn.backward", help: "Undo last draft change", action: onUndo)
                .keyboardShortcut("z", modifiers: .command)
            toolbarButton("arrow.uturn.forward", help: "Redo last draft change", action: onRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])

            Divider().frame(height: 18)

            Menu {
                Button(action: onNewDraft) {
                    Label("New Draft", systemImage: "doc.badge.plus")
                }

                Divider()

                if draftDescriptors.isEmpty {
                    Text(isLoadingDrafts ? "Loading Markdown drafts…" : "No Markdown drafts found")
                } else {
                    Section("Workspace Markdown") {
                        ForEach(draftDescriptors) { descriptor in
                            Button {
                                onSelectDraft(descriptor.relativePath)
                            } label: {
                                Label(
                                    descriptor.relativePath,
                                    systemImage: selectedDraftPath == descriptor.relativePath
                                        ? "checkmark"
                                        : descriptor.isEditorialDraft ? "doc.text.fill" : "doc.text"
                                )
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text(draftName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if hasUnsavedChanges {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: 220)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .help("Select a Markdown draft from the active workspace")
            .accessibilityLabel("Current draft: \(draftName)")
            .accessibilityValue(hasUnsavedChanges ? "Unsaved changes" : "Saved")

            Spacer()

            Label("Editorial assistant active", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .help("The editorial assistant is available for the actions in the draft menu.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func toolbarButton(
        _ icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
