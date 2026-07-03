import SwiftUI

// MARK: - ThreadRowView — single row in the sidebar thread list

struct ThreadRowView: View {
    let thread: Thread
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onPin: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onRestore: () -> Void

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameText: String = ""

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Pin indicator
                if thread.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(45))
                }

                // Thread info
                VStack(alignment: .leading, spacing: 2) {
                    if isRenaming {
                        TextField("Thread name", text: $renameText, onCommit: {
                            let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                onRename(trimmed)
                            }
                            isRenaming = false
                        })
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                    } else {
                        Text(thread.title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? .primary : .primary)
                    }

                    Text(thread.updatedAt, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                // Mode badge
                if thread.mode == .plan {
                    Text("PLAN")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.1)
                    : isHovering
                        ? Color.primary.opacity(0.04)
                        : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
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
