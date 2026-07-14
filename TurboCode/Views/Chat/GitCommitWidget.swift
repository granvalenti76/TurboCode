import SwiftUI

struct GitCommitWidget: View {
    let blockID: String
    let receipt: GitCommitBlock

    @Environment(ChatStore.self) private var chatStore
    @State private var copied = false
    @State private var showsUndoConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label(receipt.branch, systemImage: "arrow.triangle.branch")
                    Text(receipt.shortHash)
                        .fontDesign(.monospaced)
                    Text("\(receipt.files.count) \(receipt.files.count == 1 ? "file" : "files")")
                    Text("+\(receipt.additions)")
                        .foregroundStyle(.green)
                    Text("-\(receipt.deletions)")
                        .foregroundStyle(.red)
                }
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let error = receipt.errorMessage {
                    Text(error)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                actionButton(
                    icon: copied ? "checkmark" : "doc.on.doc",
                    help: copied ? "Commit hash copied" : "Copy commit hash"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(receipt.hash, forType: .string)
                    copied = true
                }

                actionButton(icon: "sidebar.right", help: "Inspect commit") {
                    chatStore.reviewGitCommit(blockID)
                }

                if receipt.status == .committed {
                    actionButton(icon: "arrow.uturn.backward", help: "Undo commit") {
                        showsUndoConfirmation = true
                    }
                } else if receipt.status == .undoing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 28, height: 28)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
        .confirmationDialog(
            "Undo this commit?",
            isPresented: $showsUndoConfirmation,
            titleVisibility: .visible
        ) {
            Button("Undo Commit", role: .destructive) {
                chatStore.undoGitCommit(blockID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The commit will be removed from HEAD. Its changes will remain staged.")
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch receipt.status {
        case .committed: receipt.message
        case .undoing: "Undoing \(receipt.shortHash)"
        case .undone: "Commit undone; changes remain staged"
        case .failed: "Could not undo \(receipt.shortHash)"
        }
    }

    private var statusIcon: String {
        switch receipt.status {
        case .committed: "checkmark.circle.fill"
        case .undoing: "clock.arrow.circlepath"
        case .undone: "arrow.uturn.backward.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch receipt.status {
        case .committed: .green
        case .undoing: .secondary
        case .undone: .blue
        case .failed: .red
        }
    }

    private func actionButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
