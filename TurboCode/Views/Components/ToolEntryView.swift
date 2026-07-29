import SwiftUI

// MARK: - ToolEntryView — collapsible tool call card

/// Replicates Kun's tool call cards:
/// - Icon per tool kind (wrench, terminal, file edit)
/// - Status badge (running / success / error)
/// - Duration display
/// - Expandable detail (diff, output)
struct ToolEntryView: View {
    let block: ToolBlock
    @State private var expanded: Bool

    init(block: ToolBlock) {
        self.block = block
        self._expanded = State(initialValue: block.status == .running)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row (always visible)
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                HStack(spacing: 10) {
                    // Icon
                    iconView

                    // Summary + status
                    VStack(alignment: .leading, spacing: 2) {
                        Text(block.summary)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        HStack(spacing: 6) {
                            statusBadge
                            if let ms = block.durationMs {
                                Text(formatDuration(ms))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Spacer()

                    // Chevron + progress
                    HStack(spacing: 6) {
                        if block.status == .running {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 14)
                        }

                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // Detail content (expandable)
            if expanded, let detail = block.detail {
                Divider()
                    .padding(.horizontal, 12)

                ScrollView([.horizontal, .vertical]) {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(12)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(toneColor.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Icon

    private var iconView: some View {
        Image(systemName: iconName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(toneColor)
            .frame(width: 28, height: 28)
            .background(toneColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch block.kind {
        case .toolCall: return "wrench"
        case .commandExecution: return "terminal"
        case .fileChange: return "doc.text"
        case .backgroundShell: return "terminal.badge.ellipsis"
        case .delegateTask: return "person.2"
        }
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        HStack(spacing: 3) {
            if block.status == .running {
                ProgressView()
                    .scaleEffect(0.5)
            }
            Text(block.status.rawValue.capitalized)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }

    private var statusColor: Color {
        switch block.status {
        case .running: return .blue
        case .success: return .green
        case .error: return .red
        }
    }

    private var toneColor: Color {
        switch block.kind {
        case .toolCall: return .blue
        case .commandExecution: return .orange
        case .fileChange: return .purple
        case .backgroundShell: return .gray
        case .delegateTask: return .indigo
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(minutes)m \(secs)s"
    }
}

// MARK: - DiffView — unified diff renderer

/// Renders a colorized unified diff with line numbers, matching Kun's DiffView.
struct DiffView: View {
    let patch: String
    var maxHeight: CGFloat = 300

    private struct DiffLine: Identifiable {
        let id: Int
        let text: String
        let lineNumber: Int?
        let type: DiffLineType
    }

    private enum DiffLineType {
        case normal
        case addition
        case deletion
        case header
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            DiffHeaderView()

            // Diff content
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(parseDiff(patch)) { line in
                        HStack(spacing: 0) {
                            Text(line.lineNumber.map { "\($0)" } ?? " ")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 36, alignment: .trailing)
                                .padding(.trailing, 8)

                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(lineColor(line.type))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .background(lineBackground(line.type))
                    }
                }
            }
            .frame(maxHeight: maxHeight)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        )
    }

    private func lineColor(_ type: DiffLineType) -> Color {
        switch type {
        case .addition: return .green
        case .deletion: return .red
        case .header: return .blue
        case .normal: return .primary
        }
    }

    private func lineBackground(_ type: DiffLineType) -> Color {
        switch type {
        case .addition: return .green.opacity(0.07)
        case .deletion: return .red.opacity(0.07)
        case .header: return .blue.opacity(0.05)
        case .normal: return .clear
        }
    }

    private func parseDiff(_ patch: String) -> [DiffLine] {
        patch
            .components(separatedBy: .newlines)
            .enumerated()
            .map { index, line in
                let type: DiffLineType
                if line.hasPrefix("+") {
                    type = .addition
                } else if line.hasPrefix("-") {
                    type = .deletion
                } else if line.hasPrefix("@@") {
                    type = .header
                } else {
                    type = .normal
                }
                return DiffLine(
                    id: index,
                    text: line,
                    lineNumber: nil,
                    type: type
                )
            }
    }
}

// MARK: - Diff Header

struct DiffHeaderView: View {
    var body: some View {
        HStack {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text("Changes")
                .font(.system(size: 11, weight: .medium))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }
}
