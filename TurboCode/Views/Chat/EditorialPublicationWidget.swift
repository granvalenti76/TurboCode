import AppKit
import SwiftUI

/// Compact native receipt shown after Editorial Desk writes a Markdown file.
/// Its quiet material treatment matches timeline widgets without suggesting
/// that an assistant response or another editorial operation occurred.
struct EditorialPublicationWidget: View {
    let publication: EditorialPublicationBlock

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Draft published")
                    .font(.system(size: 13, weight: .semibold))

                Text(publication.fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detailText)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(action: revealInFinder) {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Show draft in Finder")
            .accessibilityLabel("Show published draft in Finder")
            .disabled(fileURL == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.green.opacity(0.22), lineWidth: 1)
        }
        .contextMenu {
            Button("Show in Finder", action: revealInFinder)
                .disabled(fileURL == nil)
            Button("Copy File Path", action: copyPath)
                .disabled(fileURL == nil)
        }
        .accessibilityElement(children: .contain)
    }

    private var detailText: String {
        let words = publication.wordCount == 1 ? "1 word" : "\(publication.wordCount) words"
        return "Saved to workspace · \(words)"
    }

    private var fileURL: URL? {
        try? WorkspacePathResolver.resolve(
            publication.relativePath,
            within: publication.workspaceRoot
        )
    }

    private func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func copyPath() {
        guard let fileURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fileURL.path, forType: .string)
    }
}
