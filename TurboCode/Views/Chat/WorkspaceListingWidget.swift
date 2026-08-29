import AppKit
import SwiftUI

/// Inline disclosure result for the immutable directory snapshot produced by
/// list_workspace. The closed state stays lightweight; the inspector remains
/// the authoritative surface for a complete review.
struct WorkspaceListingWidget: View {
    let blockID: String
    let listing: WorkspaceListingBlock

    @Environment(ChatStore.self) private var chatStore
    @State private var isExpanded = false
    @State private var showsAllEntries = false

    private let previewLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: handleHeaderAction) {
                header
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityHeaderLabel)
            .accessibilityHint(accessibilityHeaderHint)

            if isExpanded {
                Divider()

                if let errorMessage = listing.errorMessage {
                    Label {
                        Text(errorMessage)
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                } else if listing.entries.isEmpty {
                    Label("Empty directory", systemImage: "folder")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                } else {
                    VStack(spacing: 0) {
                        ForEach(visibleEntries) { entry in
                            fileRow(entry)

                            if entry.id != visibleEntries.last?.id {
                                Divider()
                                    .padding(.leading, 44)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            footer
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .contextMenu {
            Button("Open Details", action: showInspector)
            Button("Open in Finder", action: openInFinder)
                .disabled(!canOpenInFinder)
            Divider()
            Button("Copy Directory Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(listing.path, forType: .string)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: disclosureSymbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .leading)

            Image(systemName: listing.errorMessage == nil ? "folder.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(listing.errorMessage == nil ? Color.blue : Color.red)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace files")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text(locationLabel)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer(minLength: 10)

            Text(countLabel)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var footer: some View {
        if isExpanded && listing.errorMessage == nil && !listing.entries.isEmpty {
            Divider()

            HStack(spacing: 10) {
                if hasExpandableContent {
                    if listing.isTruncated {
                        Button("Open captured list", action: showInspector)
                    } else {
                        Button(showsAllEntries ? "Show less" : "Show all", action: toggleAllEntries)
                    }
                }

                Spacer(minLength: 8)

                Button(action: showInspector) {
                    Image(systemName: "info.circle")
                }
                .help("Open details in inspector")
                .accessibilityLabel("Open details")

                Button {
                    openInFinder()
                } label: {
                    Label("Open in Finder", systemImage: "arrow.up.forward.square")
                }
                .help("Reveal this directory in Finder")
                    .disabled(!canOpenInFinder)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(AppTypography.metadata)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func fileRow(_ entry: WorkspaceListingEntry) -> some View {
        WorkspaceListingFileRow(entry: entry)
    }

    private var visibleEntries: [WorkspaceListingEntry] {
        guard isExpanded else { return [] }
        // A truncated snapshot never claims to contain the complete directory.
        if listing.isTruncated || !showsAllEntries {
            return Array(listing.entries.prefix(previewLimit))
        }
        return listing.entries
    }

    private var hasExpandableContent: Bool {
        listing.entries.count > previewLimit
    }

    private var displayPath: String {
        listing.path == "." ? "Workspace Root" : listing.path
    }

    private var locationLabel: String {
        guard let workspaceName = listing.workspaceName else { return displayPath }
        guard listing.path != "." else { return workspaceName }
        return "\(workspaceName) › \(displayPath)"
    }

    private var disclosureSymbolName: String {
        guard listing.errorMessage == nil, !listing.entries.isEmpty else {
            return "info.circle"
        }
        return isExpanded ? "chevron.down" : "chevron.right"
    }

    private var countLabel: String {
        if listing.errorMessage != nil { return "Details" }

        let count = listing.totalCount
        return listing.isTruncated
            ? "\(listing.entries.count) of \(count) items"
            : "\(count) \(count == 1 ? "item" : "items")"
    }

    private var canOpenInFinder: Bool {
        guard !chatStore.workspaceRoot.isEmpty else { return false }
        return (try? WorkspacePathResolver.resolve(
            listing.path,
            within: chatStore.workspaceRoot
        )) != nil
    }

    private var accessibilityHeaderLabel: String {
        "Workspace files, \(countLabel)"
    }

    private var accessibilityHeaderHint: String {
        if listing.errorMessage != nil || listing.entries.isEmpty {
            return "Shows directory details in the inspector"
        }
        return isExpanded ? "Collapses the file list" : "Expands the file list"
    }

    private func handleHeaderAction() {
        if listing.errorMessage == nil && !listing.entries.isEmpty {
            toggleExpanded()
        } else {
            showInspector()
        }
    }

    private func toggleExpanded() {
        withAnimation(.snappy) {
            isExpanded.toggle()
            if !isExpanded {
                showsAllEntries = false
            }
        }
    }

    private func toggleAllEntries() {
        withAnimation(.snappy) {
            showsAllEntries.toggle()
        }
    }

    private func showInspector() {
        chatStore.reviewWorkspaceListing(blockID)
    }

    /// Reveals only the captured directory path inside the active workspace;
    /// the shared resolver keeps historical tool paths inside that boundary.
    private func openInFinder() {
        guard let url = try? WorkspacePathResolver.resolve(
            listing.path,
            within: chatStore.workspaceRoot
        ) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

}

/// One live workspace entry. Editorial recognition is presentation-only and
/// bounded to front matter, preserving the immutable browse_files receipt.
private struct WorkspaceListingFileRow: View {
    let entry: WorkspaceListingEntry

    @Environment(ChatStore.self) private var chatStore
    @State private var editorialSummary: EditorialDraftSummary?
    @State private var isHovered = false

    var body: some View {
        Group {
            if editorialSummary != nil {
                Button(action: openEditorialDraft) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .task(id: recognitionKey) {
            guard isEditorialCandidate else {
                editorialSummary = nil
                return
            }
            editorialSummary = await chatStore.editorialDraftSummary(
                relativePath: entry.relativePath
            )
        }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.16), value: showsEditorialHover)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                Text(entry.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Text(detailLabel)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            if showsEditorialHover, let editorialSummary {
                editorialHoverCard(editorialSummary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        .background {
            if showsEditorialHover {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.045))
                    .padding(.horizontal, 5)
            }
        }
    }

    private func editorialHoverCard(_ summary: EditorialDraftSummary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 2) {
                Text("Editorial Desk")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(displayTitle(for: summary))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let metadataLabel = metadataLabel(for: summary) {
                    Text(metadataLabel)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Text("Open")
                Image(systemName: "chevron.forward")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    private var recognitionKey: String {
        "\(chatStore.workspaceRoot)|\(entry.relativePath)|\(entry.modifiedAt ?? "")"
    }

    private var isEditorialCandidate: Bool {
        entry.kind == .file && entry.fileExtension == "md"
    }

    private var showsEditorialHover: Bool {
        isHovered && editorialSummary != nil
    }

    private var helpText: String {
        guard let editorialSummary else { return entry.relativePath }
        return "Open \(displayTitle(for: editorialSummary)) in Editorial Desk"
    }

    private var accessibilityLabel: String {
        guard let editorialSummary else { return entry.name }
        return "\(displayTitle(for: editorialSummary)), Editorial Desk draft"
    }

    private var accessibilityHint: String {
        editorialSummary == nil ? detailLabel : "Opens the article in Editorial Desk"
    }

    private func openEditorialDraft() {
        guard editorialSummary != nil else { return }
        chatStore.presentEditorialDesk(draftRelativePath: entry.relativePath)
    }

    private func displayTitle(for summary: EditorialDraftSummary) -> String {
        let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? URL(fileURLWithPath: entry.name).deletingPathExtension().lastPathComponent
            : title
    }

    private func metadataLabel(for summary: EditorialDraftSummary) -> String? {
        let components = [summary.sectionName, summary.typeName].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return components.isEmpty ? "Editorial Draft" : components.joined(separator: " · ")
    }

    private var detailLabel: String {
        switch entry.kind {
        case .directory:
            "Folder"
        case .symbolicLink:
            "Link"
        case .file:
            entry.sizeBytes.map {
                ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
            } ?? "File"
        }
    }

    private var iconName: String {
        switch entry.kind {
        case .directory: "folder.fill"
        case .symbolicLink: "link"
        case .file:
            switch entry.fileExtension {
            case "swift": "swift"
            case "xcodeproj", "xcworkspace": "hammer.fill"
            case "md", "txt": "doc.text.fill"
            case "json", "plist", "yaml", "yml": "curlybraces"
            case "png", "jpg", "jpeg", "heic", "svg": "photo.fill"
            default: "doc.fill"
            }
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .directory: .blue
        case .symbolicLink: .purple
        case .file where entry.fileExtension == "swift": .orange
        case .file: .secondary
        }
    }
}
