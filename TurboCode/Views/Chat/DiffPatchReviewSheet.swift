import AppKit
import SwiftUI

/// Native document-modal review for immutable edit_file snapshots. The sheet
/// uses the system presentation animation and focus model instead of emulating
/// a modal with a custom overlay.
struct DiffPatchReviewSheet: View {
    let patch: DiffPatchBlock

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath: String?

    private var snapshots: [DiffReviewFileSnapshot] {
        let order = Dictionary(uniqueKeysWithValues: patch.files.enumerated().map { ($1.path, $0) })
        return (patch.reviewFiles ?? []).sorted {
            (order[$0.path] ?? .max) < (order[$1.path] ?? .max)
        }
    }

    private var selectedSnapshot: DiffReviewFileSnapshot? {
        snapshots.first(where: { $0.path == selectedPath }) ?? snapshots.first
    }

    init(patch: DiffPatchBlock) {
        self.patch = patch
        _selectedPath = State(initialValue: patch.reviewFiles?.first?.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if snapshots.count > 1 {
                HSplitView {
                    fileSidebar
                        .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                    reviewDetail
                        .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                reviewDetail
            }
        }
        .frame(minWidth: 860, idealWidth: 1080, minHeight: 580, idealHeight: 720)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Review Changes", systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 16, weight: .semibold))

            Text("Captured when the edit was applied")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)

            Spacer()

            changeSummary(additions: patch.additions, deletions: patch.deletions)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(.bar)
    }

    private var fileSidebar: some View {
        List(snapshots, selection: $selectedPath) { snapshot in
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: snapshot.path).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                let parent = (snapshot.path as NSString).deletingLastPathComponent
                if !parent.isEmpty {
                    Text(parent)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .tag(snapshot.path)
            .help(snapshot.path)
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Changed files")
    }

    @ViewBuilder
    private var reviewDetail: some View {
        if let snapshot = selectedSnapshot {
            let fileChange = patch.files.first(where: { $0.path == snapshot.path })
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(snapshot.path)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    // The global summary already describes a single-file edit.
                    // Keep the local count only when it helps compare files.
                    if snapshots.count > 1, let fileChange {
                        changeSummary(
                            additions: fileChange.additions,
                            deletions: fileChange.deletions
                        )
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                DiffReviewFileView(snapshot: snapshot)
            }
        } else {
            ContentUnavailableView(
                "Review unavailable",
                systemImage: "doc.badge.ellipsis",
                description: Text("This receipt does not contain a full-file snapshot.")
            )
        }
    }

    private func changeSummary(additions: Int, deletions: Int) -> some View {
        HStack(spacing: 8) {
            Text("+\(additions)")
                .foregroundStyle(.green)
            Text("−\(deletions)")
                .foregroundStyle(.red)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) additions, \(deletions) deletions")
    }
}

private struct DiffReviewFileView: View {
    let snapshot: DiffReviewFileSnapshot
    private let lines: [DiffReviewLine]
    private let lineNumberColumnWidth: CGFloat
    private let minimumContentWidth: CGFloat

    init(snapshot: DiffReviewFileSnapshot) {
        self.snapshot = snapshot
        let lines = DiffReviewLineBuilder.lines(
            original: snapshot.originalText,
            modified: snapshot.modifiedText
        )
        self.lines = lines
        lineNumberColumnWidth = DiffReviewLayout.lineNumberColumnWidth(for: lines)
        minimumContentWidth = DiffReviewLayout.minimumContentWidth(
            for: lines,
            lineNumberColumnWidth: lineNumberColumnWidth
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width, minimumContentWidth)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        DiffReviewLineRow(
                            line: line,
                            lineNumberColumnWidth: lineNumberColumnWidth
                        )
                        // A concrete width creates genuine horizontal overflow;
                        // LazyVStack otherwise adopts the viewport and clips text.
                        .frame(width: contentWidth, alignment: .leading)
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("Full file changes for \(snapshot.path)")
    }
}

private struct DiffReviewLineRow: View {
    let line: DiffReviewLine
    let lineNumberColumnWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                lineNumber(line.oldLineNumber)
                lineNumber(line.newLineNumber)
            }
            .background(Color.primary.opacity(0.022))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 0.5)
            }

            Text(line.kind.marker)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(line.kind.markerColor)
                .frame(width: DiffReviewLayout.markerWidth)

            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 16)
        }
        .frame(minHeight: 21)
        .background(line.kind.backgroundColor)
        .overlay(alignment: .leading) {
            if line.kind != .context {
                Rectangle()
                    .fill(line.kind.markerColor)
                    .frame(width: 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityLabel)
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.leading, 6)
            .frame(width: lineNumberColumnWidth, alignment: .leading)
    }
}

/// Keeps the diff gutter compact while still reserving enough canvas for the
/// longest unwrapped line. Explicit sizing is required because a lazy stack in
/// a two-axis ScrollView does not infer horizontal overflow from its children.
private enum DiffReviewLayout {
    static let markerWidth: CGFloat = 20
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func lineNumberColumnWidth(for lines: [DiffReviewLine]) -> CGFloat {
        let largestNumber = lines.reduce(0) { partial, line in
            max(partial, max(line.oldLineNumber ?? 0, line.newLineNumber ?? 0))
        }
        let digits = max(String(largestNumber).count, 1)
        return max(28, CGFloat(digits * 7 + 10))
    }

    static func minimumContentWidth(
        for lines: [DiffReviewLine],
        lineNumberColumnWidth: CGFloat
    ) -> CGFloat {
        let longestCodeWidth = lines.reduce(CGFloat.zero) { width, line in
            let measured = (line.text as NSString).size(
                withAttributes: [.font: codeFont]
            ).width
            return max(width, measured)
        }
        let gutterWidth = lineNumberColumnWidth * 2
        // Trailing breathing room prevents the final glyph from sitting under
        // the overlay scroller when the system uses automatic scroll bars.
        return gutterWidth + markerWidth + longestCodeWidth + 24
    }
}

nonisolated enum DiffReviewLineKind: Sendable, Hashable {
    case context
    case addition
    case removal

    var marker: String {
        switch self {
        case .context: " "
        case .addition: "+"
        case .removal: "−"
        }
    }

    var accessibilityName: String {
        switch self {
        case .context: "Unchanged"
        case .addition: "Added"
        case .removal: "Removed"
        }
    }

    @MainActor var markerColor: Color {
        switch self {
        case .context: .clear
        case .addition: .green
        case .removal: .red
        }
    }

    @MainActor var backgroundColor: Color {
        switch self {
        case .context: .clear
        case .addition: .green.opacity(0.12)
        case .removal: .red.opacity(0.12)
        }
    }
}

nonisolated struct DiffReviewLine: Identifiable, Sendable, Hashable {
    let id: Int
    let kind: DiffReviewLineKind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String

    var accessibilityLabel: String {
        let lineNumber = newLineNumber ?? oldLineNumber
        let location = lineNumber.map { "line \($0)" } ?? "line"
        return "\(kind.accessibilityName), \(location): \(text)"
    }
}

/// Converts Swift's collection difference into a complete inline file view.
/// Unchanged lines remain visible while additions and removals keep independent
/// old/new gutters, matching familiar source-review conventions.
nonisolated enum DiffReviewLineBuilder {
    static func lines(original: String?, modified: String?) -> [DiffReviewLine] {
        let oldLines = split(original ?? "")
        let newLines = split(modified ?? "")
        let difference = newLines.difference(from: oldLines)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()

        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        var result: [DiffReviewLine] = []
        var oldIndex = 0
        var newIndex = 0

        func append(_ kind: DiffReviewLineKind, old: Int?, new: Int?, text: String) {
            result.append(
                DiffReviewLine(
                    id: result.count,
                    kind: kind,
                    oldLineNumber: old.map { $0 + 1 },
                    newLineNumber: new.map { $0 + 1 },
                    text: text
                )
            )
        }

        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removedOffsets.contains(oldIndex) {
                append(.removal, old: oldIndex, new: nil, text: oldLines[oldIndex])
                oldIndex += 1
            } else if newIndex < newLines.count, insertedOffsets.contains(newIndex) {
                append(.addition, old: nil, new: newIndex, text: newLines[newIndex])
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count,
                      oldLines[oldIndex] == newLines[newIndex] {
                append(.context, old: oldIndex, new: newIndex, text: newLines[newIndex])
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < oldLines.count {
                // Defensive fallback for an unexpected or associated move shape.
                append(.removal, old: oldIndex, new: nil, text: oldLines[oldIndex])
                oldIndex += 1
            } else if newIndex < newLines.count {
                append(.addition, old: nil, new: newIndex, text: newLines[newIndex])
                newIndex += 1
            }
        }

        return result
    }

    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}
