import SwiftUI

// MARK: - InspectorPanelView

struct InspectorPanelView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        Group {
            if chatStore.isLoadingDiffs {
                loadingView
            } else if let error = chatStore.diffLoadError {
                emptyView(title: "Choose a workspace", subtitle: error)
            } else if chatStore.diffSections.isEmpty {
                emptyView(title: "No changes yet", subtitle: "Working tree is clean")
            } else {
                FileInspectorView(
                    sections: chatStore.diffSections,
                    projectFolderURL: URL(fileURLWithPath: chatStore.workspaceRoot)
                )
            }
        }
        .background(.background)
        .frame(minWidth: 280)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty / Error View

    private func emptyView(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.green)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - FileInspectorView

struct FileInspectorView: View {
    let sections: [FileDiffSection]
    let projectFolderURL: URL?
    @State private var collapsed: Set<String> = []
    @State private var showOnlyChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.plaintext").font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Changed Files").font(AppTypography.controlEmphasized).foregroundStyle(.secondary)
            Spacer()

            Button {
                showOnlyChanges.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: showOnlyChanges ? "doc.text.below.ecg" : "doc.text")
                        .font(.system(size: 11))
                    Text(showOnlyChanges ? "Changes" : "Full")
                        .font(AppTypography.metadata)
                }
                .foregroundStyle(showOnlyChanges ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(showOnlyChanges ? "Show full diff with context" : "Show only added/removed lines")

            Text("\(sections.count) \(sections.count == 1 ? "file" : "files")")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8).frame(minHeight: 36)
    }

    @ViewBuilder
    private var contentArea: some View {
        if sections.isEmpty {
            emptyPlaceholder
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(sections) { section in
                        DiffSectionView(
                            section: section,
                            isCollapsed: collapsed.contains(section.id),
                            showOnlyChanges: showOnlyChanges,
                            onToggle: { toggle(section.id) }
                        )
                        if section.id != sections.last?.id { Divider().padding(.leading, 12) }
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) }
        else { collapsed.insert(id) }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 24)).foregroundStyle(.secondary)
            Text("No changed files").font(AppTypography.sidebarLabel).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DiffSectionView

struct DiffSectionView: View {
    let section: FileDiffSection
    let isCollapsed: Bool
    let showOnlyChanges: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }

            if !isCollapsed, !section.diffLines.isEmpty {
                DiffLinesView(lines: showOnlyChanges ? onlyChanges(section.diffLines) : section.diffLines)
            }
        }
    }

    private func onlyChanges(_ lines: [DiffLine]) -> [DiffLine] {
        lines.filter { $0.type != .context }
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 10)
            Image(systemName: "doc.plaintext").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.fileName).font(AppTypography.controlEmphasized).lineLimit(1)
                Text(section.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if section.added > 0 { Text("+\(section.added)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.green) }
            if section.removed > 0 { Text("-\(section.removed)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.red) }
        }
    }
}

// MARK: - DiffLinesView

struct DiffLinesView: View {
    let lines: [DiffLine]
    @State private var contentWidth: CGFloat = 300

    var body: some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    DiffLineView(line: line)
                }
            }
            .font(AppTypography.code)
            .textSelection(.enabled)
            .frame(minWidth: contentWidth, alignment: .leading)
        }
        .overlay {
            GeometryReader { geo in
                Color.clear.task(id: geo.size.width) { contentWidth = geo.size.width }
            }
        }
    }
}

// MARK: - DiffLineView

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(prefix).foregroundStyle(prefixColor).frame(width: 10, alignment: .center)
                Text(lineNumberStr).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            }
            .padding(.leading, 6).padding(.trailing, 8).background(gutterBg)

            Rectangle().fill(stripeColor).frame(width: 3)

            Text(line.content).foregroundStyle(.primary).lineLimit(nil)
                .padding(.leading, 10).padding(.trailing, 8)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1).background(contentBg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gutterBg: Color {
        switch line.type { case .added: return .green.opacity(0.18); case .removed: return .red.opacity(0.18); case .context: return .clear }
    }
    private var contentBg: Color {
        switch line.type { case .added: return .green.opacity(0.08); case .removed: return .red.opacity(0.08); case .context: return .clear }
    }
    private var prefix: String {
        switch line.type { case .added: return "+"; case .removed: return "-"; case .context: return " " }
    }
    private var displayLineNumber: Int? {
        switch line.type { case .added: return line.newLineNumber; case .removed: return line.oldLineNumber; case .context: return line.newLineNumber ?? line.oldLineNumber }
    }
    private var lineNumberStr: String {
        guard let ln = displayLineNumber else { return " " }; return String(format: "%3d", ln)
    }
    private var prefixColor: Color {
        switch line.type { case .added: return .green; case .removed: return .red; case .context: return .clear }
    }
    private var stripeColor: Color {
        switch line.type { case .added: return .green.opacity(0.5); case .removed: return .red.opacity(0.5); case .context: return .clear }
    }
}
