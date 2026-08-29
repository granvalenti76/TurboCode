import SwiftUI

/// Presents draft statistics and the publication boundary. The publication
/// coordinator remains owned by the sheet and is reached only through closures.
struct EditorialDeskFooter: View {
    let viewModel: EditorialDeskViewModel
    let publicationPhase: EditorialPublicationPhase
    let publicationReceipt: EditorialPublication?
    let isPublishing: Bool
    let onDismiss: () -> Void
    let onPublish: () -> Void
    let onRetryHandoff: () -> Void

    private var wordCount: Int {
        viewModel.draftText.split(whereSeparator: { $0.isWhitespace }).count
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            footerStat("Words", value: "\(wordCount)")
            footerDivider
            footerStat("Reading", value: wordCount == 0 ? "—" : "\(max(1, wordCount / 210)) min")
            footerDivider
            footerStat(
                "Sources",
                value: "\(viewModel.selectedSources.count)/\(viewModel.sources.count)"
            )
            footerDivider
            Label(viewModel.hasDocument ? "Draft ready" : "Empty desk", systemImage: "checkmark")
            if let publicationReceipt, publicationPhase == .handoffFailed {
                footerDivider
                Label("File saved: \(publicationReceipt.fileName)", systemImage: "checkmark.circle")
                    .foregroundStyle(.orange)
                    .help(publicationReceipt.url.path)
            }

            Spacer()

            Button(viewModel.isRunning ? "Stop operation first" : "Cancel") {
                onDismiss()
            }
            .buttonStyle(.bordered)
            .disabled(isPublishing || viewModel.isRunning)

            Menu {
                if publicationPhase == .handoffFailed {
                    Button {
                        onRetryHandoff()
                    } label: {
                        Label("Retry handoff", systemImage: "arrow.clockwise")
                    }
                } else {
                    Button {
                        onPublish()
                    } label: {
                        if isPublishing {
                            Label("Publishing…", systemImage: "arrow.up.circle")
                        } else {
                            Label("Publish now", systemImage: "arrow.up.circle")
                        }
                    }
                    .disabled(isPublishing)
                }
            } label: {
                HStack(spacing: 8) {
                    if isPublishing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        isPublishing
                            ? "Publishing…"
                            : publicationPhase == .handoffFailed ? "Retry handoff" : "Publish Draft"
                    )
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.hasDocument || isPublishing)
            .accessibilityLabel(isPublishing ? "Publishing draft" : "Publish draft")
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
            .accessibilityHidden(true)
    }
}
