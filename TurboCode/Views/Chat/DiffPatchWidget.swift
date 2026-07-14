import SwiftUI

struct DiffPatchWidget: View {
    let blockID: String
    let patch: DiffPatchBlock

    @Environment(ChatStore.self) private var chatStore
    @State private var showsAllFiles = false
    @State private var displayedAdditions = 0
    @State private var displayedDeletions = 0

    private var displayedFiles: ArraySlice<DiffPatchFileChange> {
        showsAllFiles ? patch.files[...] : patch.files.prefix(3)
    }

    private var hiddenFileCount: Int {
        max(0, patch.files.count - displayedFiles.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !patch.files.isEmpty {
                Divider()
                fileList
            }

            if let error = patch.errorMessage, !error.isEmpty {
                Divider()
                Text(error)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: patch.status) {
            await animateCountsIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary.opacity(0.45))
                if patch.status == .running || patch.status == .undoing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("+\(displayedAdditions)")
                        .foregroundStyle(.green)
                        .contentTransition(.numericText())
                    Text("-\(displayedDeletions)")
                        .foregroundStyle(.red)
                        .contentTransition(.numericText())
                }
                .font(.system(size: 12, design: .monospaced))
            }

            Spacer(minLength: 8)

            if patch.status == .applied {
                Button {
                    chatStore.undoDiffPatch(blockID)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
            }

            if patch.status == .applied || patch.status == .undone {
                Button("Review") {
                    chatStore.reviewDiffPatch(blockID)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            ForEach(displayedFiles) { file in
                HStack(spacing: 8) {
                    filePath(file.path)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    if file.additions > 0 {
                        Text("+\(file.additions)")
                            .foregroundStyle(.green)
                    }
                    if file.deletions > 0 {
                        Text("-\(file.deletions)")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if hiddenFileCount > 0 {
                Divider()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsAllFiles = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Show \(hiddenFileCount) more \(hiddenFileCount == 1 ? "file" : "files")")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func filePath(_ path: String) -> Text {
        let fileName = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != ".", parent != "/" else {
            return Text(fileName).foregroundStyle(.primary)
        }
        let parentText = Text(parent + "/").foregroundStyle(.secondary)
        let fileText = Text(fileName).foregroundStyle(.primary)
        return Text("\(parentText)\(fileText)")
    }

    private var title: String {
        let count = patch.files.count
        let noun = count == 1 ? "file" : "files"
        switch patch.status {
        case .awaitingApproval: return "Proposed edits to \(count) \(noun)"
        case .running: return "Editing \(count) \(noun)"
        case .applied: return "Edited \(count) \(noun)"
        case .undoing: return "Reverting \(count) \(noun)"
        case .undone: return "Reverted \(count) \(noun)"
        case .failed: return "Could not edit \(count) \(noun)"
        case .rejected: return "Edits not applied"
        }
    }

    private var statusIcon: String {
        switch patch.status {
        case .awaitingApproval: return "hand.raised"
        case .applied: return "checkmark.rectangle.stack"
        case .undone: return "arrow.uturn.backward.circle"
        case .failed: return "exclamationmark.triangle"
        case .rejected: return "xmark.circle"
        case .running, .undoing: return "doc.badge.plus"
        }
    }

    @MainActor
    private func animateCountsIfNeeded() async {
        guard patch.status == .running || patch.status == .applied else {
            displayedAdditions = patch.additions
            displayedDeletions = patch.deletions
            return
        }

        let startAdditions = displayedAdditions
        let startDeletions = displayedDeletions
        let steps = 12

        for step in 1...steps {
            guard !Task.isCancelled else { return }
            let progress = Double(step) / Double(steps)
            withAnimation(.linear(duration: 0.03)) {
                displayedAdditions = startAdditions
                    + Int(Double(patch.additions - startAdditions) * progress)
                displayedDeletions = startDeletions
                    + Int(Double(patch.deletions - startDeletions) * progress)
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        displayedAdditions = patch.additions
        displayedDeletions = patch.deletions
    }
}
