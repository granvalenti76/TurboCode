import AppKit
import SwiftUI

/// Compact timeline receipt for a structured, persisted directory snapshot.
/// Detailed metadata belongs in the inspector so tool results don't create a
/// second scrolling surface inside the conversation.
struct WorkspaceListingWidget: View {
    let blockID: String
    let listing: WorkspaceListingBlock

    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        HStack(spacing: 10) {
            Button(action: showInspector) {
                HStack(spacing: 10) {
                    Image(systemName: listing.errorMessage == nil ? "folder.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(listing.errorMessage == nil ? Color.blue : Color.red)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let workspaceName = listing.workspaceName, displayPath != "Workspace Root" {
                            Text(workspaceName)
                                .font(AppTypography.metadata)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 12)

                    Text(countLabel)
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(title), \(countLabel)")
            .accessibilityHint("Shows this directory snapshot in the inspector")

            Button("Show", action: showInspector)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Show workspace files in the inspector")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 46)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .contextMenu {
            Button("Copy Directory Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(listing.path, forType: .string)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var displayPath: String {
        listing.path == "." ? "Workspace Root" : listing.path
    }

    private var title: String {
        listing.errorMessage == nil
            ? "Listed \(displayPath)"
            : "Couldn’t list \(displayPath)"
    }

    private var countLabel: String {
        if listing.errorMessage != nil { return "Details" }
        let count = listing.totalCount
        return listing.isTruncated
            ? "\(listing.entries.count) of \(count) items"
            : "\(count) \(count == 1 ? "item" : "items")"
    }

    private func showInspector() {
        chatStore.reviewWorkspaceListing(blockID)
    }
}
