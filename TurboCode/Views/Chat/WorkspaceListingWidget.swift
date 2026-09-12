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
    @State private var selectedEntryID: String?
    @State private var displayMode: DisplayMode = .split

    private let previewLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

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
                    listingContent
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

    /// Split mode is the default from the approved mock; list-only mode keeps
    /// dense results useful when the conversation column is temporarily narrow.
    @ViewBuilder
    private var listingContent: some View {
        if displayMode == .list {
            fileList
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 0) {
                fileList
                    .frame(minWidth: 260, idealWidth: 360, maxWidth: 420)
                Divider()
                WorkspaceFilePreviewPane(
                    entry: selectedEntry,
                    canUseLiveWorkspace: canUseLiveWorkspace
                )
                .frame(minWidth: 360, maxWidth: .infinity)
                .layoutPriority(1)
            }
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
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

            if hasExpandableContent {
                Divider()
                HStack {
                    if listing.isTruncated {
                        Button("Open captured list", action: showInspector)
                    } else {
                        Button(
                            showsAllEntries ? "Show fewer" : showAllLabel,
                            action: toggleAllEntries
                        )
                    }
                    Spacer(minLength: 8)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(AppTypography.metadata)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: handleHeaderAction) {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityHeaderLabel)
            .accessibilityHint(accessibilityHeaderHint)

            Spacer(minLength: 10)

            Text(countLabel)
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if isExpanded,
               listing.errorMessage == nil,
               !listing.entries.isEmpty {
                Picker("View", selection: $displayMode) {
                    Label("List", systemImage: "list.bullet")
                        .tag(DisplayMode.list)
                    Label("Split", systemImage: "rectangle.split.2x1")
                        .tag(DisplayMode.split)
                }
                .labelsHidden()
                .labelStyle(.iconOnly)
                .pickerStyle(.segmented)
                .frame(width: 76)
                .help("Choose list or split view")
                .accessibilityLabel("Workspace file view")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var footer: some View {
        if isExpanded && listing.errorMessage == nil && !listing.entries.isEmpty {
            Divider()

            HStack(spacing: 10) {
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
        WorkspaceListingFileRow(
            entry: entry,
            isSelected: selectedEntryID == entry.id,
            canUseLiveActions: canUseLiveWorkspace,
            onSelect: { selectedEntryID = entry.id }
        )
    }

    private var selectedEntry: WorkspaceListingEntry? {
        listing.entries.first { $0.id == selectedEntryID }
    }

    private var canUseLiveWorkspace: Bool {
        chatStore.canUseLiveWorkspaceListing()
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

    private var showAllLabel: String {
        let count = listing.entries.count
        return "Show all \(count) \(count == 1 ? "item" : "items")"
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
        guard canUseLiveWorkspace else { return false }
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
            } else if selectedEntryID == nil {
                selectedEntryID = listing.entries.prefix(previewLimit).first(where: { $0.kind == .file })?.id
                    ?? listing.entries.first?.id
            }
        }
    }

    private func toggleAllEntries() {
        withAnimation(.snappy) {
            if showsAllEntries,
               let selectedEntryID,
               !listing.entries.prefix(previewLimit).contains(where: { $0.id == selectedEntryID }) {
                self.selectedEntryID = listing.entries.prefix(previewLimit).first(where: { $0.kind == .file })?.id
                    ?? listing.entries.first?.id
            }
            showsAllEntries.toggle()
        }
    }

    private func showInspector() {
        chatStore.reviewWorkspaceListing(blockID)
    }

    /// Reveals only the captured directory path inside the active workspace;
    /// the shared resolver keeps historical tool paths inside that boundary.
    private func openInFinder() {
        guard canUseLiveWorkspace else { return }
        guard let url = try? WorkspacePathResolver.resolve(
            listing.path,
            within: chatStore.workspaceRoot
        ) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private enum DisplayMode: Hashable {
        case list
        case split
    }

}

/// One live workspace entry. Editorial recognition is presentation-only and
/// bounded to front matter, preserving the immutable browse_files receipt.
private struct WorkspaceListingFileRow: View {
    let entry: WorkspaceListingEntry
    let isSelected: Bool
    let canUseLiveActions: Bool
    let onSelect: () -> Void

    @Environment(ChatStore.self) private var chatStore
    @State private var editorialSummary: EditorialDraftSummary?
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            rowContent
        }
        .buttonStyle(.plain)
        .task(id: recognitionKey) {
            guard canUseLiveActions, isEditorialCandidate else {
                editorialSummary = nil
                return
            }
            editorialSummary = await chatStore.editorialDraftSummary(
                relativePath: entry.relativePath
            )
        }
        .onHover { isHovered = $0 }
        .help(helpText)
        .contextMenu {
            Button("Preview", action: onSelect)
            if editorialSummary != nil {
                Button("Open in Editorial Desk", action: openEditorialDraft)
                    .disabled(!canUseLiveActions)
            }
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                entryIcon

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

        }
        .contentShape(Rectangle())
        .background {
            if isSelected || isHovered {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.13)
                            : Color.primary.opacity(0.045)
                    )
                    .padding(.horizontal, 5)
            }
        }
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    /// A persistent seal distinguishes Editorial Desk drafts without changing
    /// row height or making the list jump as the pointer moves between files.
    private var entryIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)

            if editorialSummary != nil {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 8, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .offset(x: 3, y: 2)
            }
        }
        .frame(width: 20)
    }

    private var recognitionKey: String {
        "\(canUseLiveActions)|\(chatStore.workspaceRoot)|\(entry.relativePath)|\(entry.modifiedAt ?? "")"
    }

    private var isEditorialCandidate: Bool {
        entry.kind == .file && entry.fileExtension == "md"
    }

    private var helpText: String {
        guard let editorialSummary else { return entry.relativePath }
        return "\(displayTitle(for: editorialSummary)) · Editorial Desk draft"
    }

    private var accessibilityLabel: String {
        guard let editorialSummary else { return entry.name }
        return "\(displayTitle(for: editorialSummary)), Editorial Desk draft"
    }

    private var accessibilityHint: String {
        editorialSummary == nil
            ? "Selects the file for preview"
            : "Selects the file for preview; Editorial Desk is available as a separate action"
    }

    private func openEditorialDraft() {
        guard canUseLiveActions, editorialSummary != nil else { return }
        chatStore.presentEditorialDesk(draftRelativePath: entry.relativePath)
    }

    private func displayTitle(for summary: EditorialDraftSummary) -> String {
        let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? URL(fileURLWithPath: entry.name).deletingPathExtension().lastPathComponent
            : title
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
