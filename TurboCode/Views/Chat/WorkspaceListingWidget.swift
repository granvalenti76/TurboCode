import SwiftUI

/// Native, persistent presentation of a structured workspace directory listing.
struct WorkspaceListingWidget: View {
    let listing: WorkspaceListingBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(14)

            Divider()

            if let errorMessage = listing.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if listing.entries.isEmpty {
                ContentUnavailableView(
                    "Empty Directory",
                    systemImage: "folder",
                    description: Text("This workspace directory contains no items.")
                )
                .frame(minHeight: 140)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(listing.entries) { entry in
                            entryRow(entry)
                            if entry.id != listing.entries.last?.id {
                                Divider().padding(.leading, 46)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            if listing.isTruncated {
                Divider()
                Label(
                    "Showing \(listing.entries.count) of \(listing.totalCount) items",
                    systemImage: "ellipsis.circle"
                )
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace directory \(displayPath), \(listing.totalCount) items")
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text("WORKSPACE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(displayPath)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Text("\(listing.totalCount) \(listing.totalCount == 1 ? "item" : "items")")
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.45), in: Capsule())
        }
    }

    private func entryRow(_ entry: WorkspaceListingEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: entry))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(iconColor(for: entry))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12.5, weight: entry.kind == .directory ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if entry.relativePath != entry.name {
                    Text(entry.relativePath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 2) {
                if let sizeBytes = entry.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }
                if let modifiedAt = formattedDate(entry.modifiedAt) {
                    Text(modifiedAt)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var displayPath: String {
        listing.path == "." ? "Workspace Root" : listing.path
    }

    private func formattedDate(_ value: String?) -> String? {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func iconName(for entry: WorkspaceListingEntry) -> String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symbolicLink: return "link"
        case .file:
            switch entry.fileExtension {
            case "swift": return "swift"
            case "xcodeproj", "xcworkspace": return "hammer.fill"
            case "md", "txt": return "doc.text.fill"
            case "json", "plist", "yaml", "yml": return "curlybraces"
            case "png", "jpg", "jpeg", "heic", "svg": return "photo.fill"
            default: return "doc.fill"
            }
        }
    }

    private func iconColor(for entry: WorkspaceListingEntry) -> Color {
        switch entry.kind {
        case .directory: .blue
        case .symbolicLink: .purple
        case .file where entry.fileExtension == "swift": .orange
        case .file: .secondary
        }
    }
}
