import SwiftUI

// MARK: - ThreadRowView — single row in the sidebar thread list

struct ThreadRowView: View {
    let thread: Conversation
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onPin: () -> Void
    let onArchive: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameText: String = ""

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                // Pin indicator
                if thread.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(45))
                }

                Group {
                    if isRenaming {
                        TextField("Thread name", text: $renameText, onCommit: {
                            let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                onRename(trimmed)
                            }
                            isRenaming = false
                        })
                        .textFieldStyle(.plain)
                        .font(AppTypography.sidebarTitle)
                    } else {
                        Text(thread.title)
                            .font(isSelected ? AppTypography.sidebarTitle.weight(.medium) : AppTypography.sidebarTitle)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                // Mode badge
                if thread.mode == .plan {
                    Text("PLAN")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isHovering && !isSelected
                    ? Color.primary.opacity(0.05)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .sidebarSelectionBackground(isSelected)
            .overlay(alignment: .trailing) {
                if isHovering && !isSelected {
                    // Quick action buttons on hover (like Kun)
                    HStack(spacing: 2) {
                        Button(action: onPin) {
                            Image(systemName: thread.isPinned ? "pin.slash" : "pin")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help(thread.isPinned ? "Unpin" : "Pin")

                        Button(action: {
                            if thread.isArchived {
                                onRestore()
                            } else {
                                onArchive()
                            }
                        }) {
                            Image(systemName: thread.isArchived ? "tray.and.arrow.up" : "archivebox")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help(thread.isArchived ? "Restore" : "Archive")

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                        .help("Delete")
                    }
                    .padding(.trailing, 4)
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: onShare) {
                Image(systemName: "square.and.arrow.up")
                    .accessibilityLabel("Share")
            }
            .tint(.secondary)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .accessibilityLabel("Delete")
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button(thread.isPinned ? "Unpin" : "Pin") { onPin() }
            Button("Rename") {
                renameText = thread.title
                isRenaming = true
            }
            Divider()
            if thread.isArchived {
                Button("Restore") { onRestore() }
            } else {
                Button("Archive") { onArchive() }
            }
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}
