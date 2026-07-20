import SwiftUI

// MARK: - Inspector Panel

struct InspectorPanelView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        Group {
            if chatStore.rightPanelMode == .workspaceListing,
               let listing = chatStore.inspectedWorkspaceListing {
                WorkspaceListingInspectorView(listing: listing)
            } else if chatStore.rightPanelMode == .commit,
               let receipt = chatStore.inspectedGitCommit {
                GitCommitInspectorView(receipt: receipt)
            } else if chatStore.isLoadingDiffs {
                stateView(icon: nil, title: "Loading changes", subtitle: nil, showsProgress: true)
            } else if let error = chatStore.diffLoadError {
                stateView(
                    icon: "exclamationmark.triangle",
                    title: "Changes unavailable",
                    subtitle: error
                )
            } else if chatStore.diffSections.isEmpty {
                stateView(
                    icon: "checkmark.circle",
                    title: "No changes",
                    subtitle: "The working tree is clean"
                )
            } else {
                FileInspectorView(sections: chatStore.diffSections)
            }
        }
        .background(.background)
    }

    private func stateView(
        icon: String?,
        title: String,
        subtitle: String?,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            if let subtitle {
                Text(subtitle)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Workspace Listing Inspector

/// Detailed view of one immutable list_workspace result. It intentionally has
/// no refresh action: a new filesystem read must create a new timeline receipt.
private struct WorkspaceListingInspectorView: View {
    let listing: WorkspaceListingBlock

    @Environment(ChatStore.self) private var chatStore
    @State private var sortOrder = [KeyPathComparator(\WorkspaceListingEntry.name)]

    private var sortedEntries: [WorkspaceListingEntry] {
        listing.entries.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let errorMessage = listing.errorMessage {
                ContentUnavailableView(
                    "Directory unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if listing.entries.isEmpty {
                ContentUnavailableView(
                    "Empty Directory",
                    systemImage: "folder",
                    description: Text("This directory contained no items in the captured snapshot.")
                )
            } else {
                Table(sortedEntries, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { entry in
                        HStack(spacing: 7) {
                            Image(systemName: iconName(for: entry))
                                .foregroundStyle(iconColor(for: entry))
                                .frame(width: 16)
                            Text(entry.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.relativePath)
                        }
                    }

                    TableColumn("Modified", value: \.sortableModifiedAt) { entry in
                        Text(formattedDate(entry.modifiedAt) ?? "—")
                            .foregroundStyle(entry.modifiedAt == nil ? .tertiary : .secondary)
                    }
                    .width(min: 82, ideal: 94)

                    TableColumn("Size", value: \.sortableSizeBytes) { entry in
                        Text(formattedSize(entry.sizeBytes) ?? "—")
                            .foregroundStyle(entry.sizeBytes == nil ? .tertiary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 52, ideal: 66)
                }
                .font(.system(size: 12))
            }

            if listing.isTruncated, listing.errorMessage == nil {
                Divider()
                Label(
                    "Showing \(listing.entries.count) of \(listing.totalCount) items. List a more specific folder for a complete result.",
                    systemImage: "ellipsis.circle"
                )
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace Files")
                    .font(.system(size: 15, weight: .semibold))

                HStack(spacing: 6) {
                    if let workspaceName = listing.workspaceName {
                        Text(workspaceName)
                        Text("·")
                    }
                    Text(displayPath)
                        .fontDesign(.monospaced)
                    Text("·")
                    Text(countLabel)
                    if let capturedAt = listing.capturedAt {
                        Text("·")
                        Text("Snapshot \(capturedAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(listing.path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy directory path")

            Button {
                chatStore.inspectedWorkspaceListingID = nil
                chatStore.rightPanelMode = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
    }

    private var displayPath: String {
        listing.path == "." ? "Workspace Root" : listing.path
    }

    private var countLabel: String {
        "\(listing.totalCount) \(listing.totalCount == 1 ? "item" : "items")"
    }

    private func formattedDate(_ value: String?) -> String? {
        guard let value, let date = ISO8601DateFormatter().date(from: value) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func formattedSize(_ value: Int?) -> String? {
        value.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    private func iconName(for entry: WorkspaceListingEntry) -> String {
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

    private func iconColor(for entry: WorkspaceListingEntry) -> Color {
        switch entry.kind {
        case .directory: .blue
        case .symbolicLink: .purple
        case .file where entry.fileExtension == "swift": .orange
        case .file: .secondary
        }
    }
}

private extension WorkspaceListingEntry {
    /// Nonoptional presentation keys let native Table column headers provide
    /// sorting while directories continue to render blank metadata cells.
    var sortableModifiedAt: String { modifiedAt ?? "" }
    var sortableSizeBytes: Int { sizeBytes ?? -1 }
}

// MARK: - Commit Inspector

private struct GitCommitInspectorView: View {
    let receipt: GitCommitBlock

    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if receipt.files.isEmpty {
                ContentUnavailableView(
                    "No file statistics",
                    systemImage: "doc.questionmark",
                    description: Text("Git did not return numstat data for this commit.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(receipt.files) { file in
                            HStack(spacing: 9) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)

                                Text(file.path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer(minLength: 8)

                                Text("+\(file.additions)")
                                    .foregroundStyle(.green)
                                Text("-\(file.deletions)")
                                    .foregroundStyle(.red)
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 38)

                            if file.id != receipt.files.last?.id {
                                Divider().padding(.leading, 37)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: receipt.status == .committed
                  ? "checkmark.circle.fill"
                  : "arrow.uturn.backward.circle.fill")
                .foregroundStyle(receipt.status == .committed ? Color.green : Color.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.message)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 7) {
                    Text(receipt.shortHash).fontDesign(.monospaced)
                    Text(receipt.branch)
                    Text("+\(receipt.additions)").foregroundStyle(.green)
                    Text("-\(receipt.deletions)").foregroundStyle(.red)
                }
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(receipt.hash, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy commit hash")

            Button {
                chatStore.rightPanelMode = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
    }
}

// MARK: - File Inspector

private enum DiffContextMode: String, CaseIterable, Identifiable {
    case focused = "Focused"
    case full = "Full"

    var id: Self { self }
}

struct FileInspectorView: View {
    let sections: [FileDiffSection]

    @Environment(ChatStore.self) private var chatStore
    @State private var collapsed: Set<String> = []
    @State private var contextMode: DiffContextMode = .focused

    private var additions: Int { sections.reduce(0) { $0 + $1.added } }
    private var deletions: Int { sections.reduce(0) { $0 + $1.removed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(sections) { section in
                        DiffSectionView(
                            section: section,
                            isCollapsed: collapsed.contains(section.id),
                            contextMode: contextMode,
                            onToggle: { toggle(section.id) }
                        )

                        if section.id != sections.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Changes")
                    .font(.system(size: 15, weight: .semibold))

                HStack(spacing: 7) {
                    Text("\(sections.count) \(sections.count == 1 ? "file" : "files")")
                        .foregroundStyle(.secondary)
                    Text("+\(additions)")
                        .foregroundStyle(.green)
                    Text("-\(deletions)")
                        .foregroundStyle(.red)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            Spacer(minLength: 8)

            Picker("Context", selection: $contextMode) {
                ForEach(DiffContextMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 126)

            Button {
                Task { await chatStore.reloadDiffs() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh changes")

            Button {
                chatStore.rightPanelMode = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
    }

    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if collapsed.contains(id) {
                collapsed.remove(id)
            } else {
                collapsed.insert(id)
            }
        }
    }
}

// MARK: - File Section

struct DiffSectionView: View {
    let section: FileDiffSection
    let isCollapsed: Bool
    fileprivate let contextMode: DiffContextMode
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                sectionHeader
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed, !section.diffLines.isEmpty {
                DiffLinesView(rows: displayRows)
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(section.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)

                if section.path != section.fileName {
                    Text(section.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                if section.added > 0 {
                    Text("+\(section.added)")
                        .foregroundStyle(.green)
                }
                if section.removed > 0 {
                    Text("-\(section.removed)")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .background(Color.primary.opacity(0.025))
    }

    private var displayRows: [InspectorDiffRow] {
        switch contextMode {
        case .full:
            return section.diffLines.enumerated().map { index, line in
                InspectorDiffRow(id: "line-\(index)-\(line.id)", content: .line(line))
            }
        case .focused:
            return focusedRows(section.diffLines, contextRadius: 3)
        }
    }

    private func focusedRows(_ lines: [DiffLine], contextRadius: Int) -> [InspectorDiffRow] {
        let changedIndices = lines.indices.filter { lines[$0].type != .context }
        guard !changedIndices.isEmpty else { return [] }

        var visibleIndices = Set<Int>()
        for index in changedIndices {
            let lower = max(lines.startIndex, index - contextRadius)
            let upper = min(lines.endIndex - 1, index + contextRadius)
            visibleIndices.formUnion(lower...upper)
        }

        var rows: [InspectorDiffRow] = []
        var omittedStart: Int?

        func appendOmitted(endingAt end: Int) {
            guard let start = omittedStart else { return }
            rows.append(
                InspectorDiffRow(
                    id: "omitted-\(start)-\(end)",
                    content: .omitted(end - start + 1)
                )
            )
            omittedStart = nil
        }

        for index in lines.indices {
            if visibleIndices.contains(index) {
                appendOmitted(endingAt: index - 1)
                rows.append(
                    InspectorDiffRow(
                        id: "line-\(index)-\(lines[index].id)",
                        content: .line(lines[index])
                    )
                )
            } else if omittedStart == nil {
                omittedStart = index
            }
        }
        appendOmitted(endingAt: lines.endIndex - 1)
        return rows
    }
}

// MARK: - Diff Rows

private struct InspectorDiffRow: Identifiable {
    enum Content {
        case line(DiffLine)
        case omitted(Int)
    }

    let id: String
    let content: Content
}

struct DiffLinesView: View {
    fileprivate let rows: [InspectorDiffRow]

    var body: some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    switch row.content {
                    case .line(let line):
                        DiffLineView(line: line)
                    case .omitted(let count):
                        omittedRow(count)
                    }
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .frame(minWidth: 419, alignment: .leading)
        }
    }

    private func omittedRow(_ count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .medium))
            Text("\(count) unchanged \(count == 1 ? "line" : "lines")")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(Color.primary.opacity(0.035))
    }
}

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(number(line.oldLineNumber))
                    .frame(width: 30, alignment: .trailing)
                Text(number(line.newLineNumber))
                    .frame(width: 30, alignment: .trailing)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(gutterBackground)

            Rectangle()
                .fill(stripeColor)
                .frame(width: 2, height: 20)

            Text(prefix)
                .foregroundStyle(prefixColor)
                .frame(width: 18, alignment: .center)

            Text(line.content.isEmpty ? " " : line.content)
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 12)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        .background(contentBackground)
    }

    private func number(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private var gutterBackground: Color {
        switch line.type {
        case .added: return .green.opacity(0.13)
        case .removed: return .red.opacity(0.13)
        case .context: return .clear
        }
    }

    private var contentBackground: Color {
        switch line.type {
        case .added: return .green.opacity(0.075)
        case .removed: return .red.opacity(0.075)
        case .context: return .clear
        }
    }

    private var prefix: String {
        switch line.type {
        case .added: return "+"
        case .removed: return "-"
        case .context: return ""
        }
    }

    private var prefixColor: Color {
        switch line.type {
        case .added: return .green
        case .removed: return .red
        case .context: return .clear
        }
    }

    private var stripeColor: Color {
        switch line.type {
        case .added: return .green.opacity(0.7)
        case .removed: return .red.opacity(0.7)
        case .context: return .clear
        }
    }
}
