import SwiftUI

/// Live column of the Transcript sheet: the tool calls of the running turn,
/// shown while the model is still writing their arguments.
///
/// The list is presentation only. It lets the user notice a small model
/// looping on the same call and stop the turn before more context is burned.
struct TranscriptLiveToolCallsView: View {
    let store: LiveToolCallStore
    /// True while the turn can still be interrupted.
    let canStop: Bool
    let onStop: () -> Void

    var body: some View {
        if store.calls.isEmpty {
            ContentUnavailableView(
                store.isActive ? "Waiting for a Tool Call" : "No Tool Calls",
                systemImage: "wrench.and.screwdriver",
                description: Text(
                    store.isActive
                        ? "Tool calls appear here as soon as the model starts writing them."
                        : "Tool calls of the running turn are shown here while the model writes them."
                )
            )
        } else {
            VStack(spacing: 0) {
                statusBar
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.calls) { call in
                            LiveToolCallCard(call: call)
                        }
                    }
                    .padding(16)
                }
                // Follows the newest fragment while the reader stays at the
                // bottom, and leaves the position alone after scrolling up.
                .defaultScrollAnchor(.bottom)
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 10) {
            if let repetition = store.repetition {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Possible loop")
                        .font(.callout.weight(.semibold))
                    Text(
                        "\(repetition.toolName) was called \(repetition.count) times "
                            + "in a row with identical arguments."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                if store.isActive {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if canStop {
                if store.repetition != nil {
                    Button("Stop Turn", role: .destructive, action: onStop)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                } else {
                    Button("Stop Turn", action: onStop)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            store.repetition == nil ? Color.clear : Color.orange.opacity(0.12)
        )
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let count = store.calls.count
        let rounds = store.calls.last?.round ?? 0
        let calls = count == 1 ? "1 tool call" : "\(count) tool calls"
        let roundText = rounds == 1 ? "1 round" : "\(rounds) rounds"
        return store.isActive
            ? "\(calls) in \(roundText) · turn running"
            : "\(calls) in \(roundText) · last turn"
    }
}

/// One tool call, with its arguments laid out as named fields.
private struct LiveToolCallCard: View {
    let call: LiveToolCall

    /// Longest value rendered in full. A file written through a tool call
    /// can reach hundreds of kilobytes, and laying out all of it again on
    /// every fragment would stall the sheet.
    private static let visibleValueLimit = 6_000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            let fields = ToolCallArgumentFormatter.fields(from: call.arguments)
            if fields.isEmpty {
                Text(call.phase == .writing ? "Waiting for arguments…" : "No arguments")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    fieldView(field)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .foregroundStyle(Color.accentColor)
            Text(call.name)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
            Text("Round \(call.round)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())

            Spacer(minLength: 8)

            Text("≈ \(call.fragmentCount.formatted(.number)) tokens")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            phaseLabel
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch call.phase {
        case .writing:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Writing")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
        case .written:
            Label("Written", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .interrupted:
            Label("Interrupted", systemImage: "stop.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        }
    }

    private var borderColor: Color {
        switch call.phase {
        case .writing: Color.accentColor.opacity(0.55)
        case .written: Color(nsColor: .separatorColor)
        case .interrupted: Color.orange.opacity(0.55)
        }
    }

    @ViewBuilder
    private func fieldView(_ field: ToolCallArgumentFormatter.Field) -> some View {
        let isBlock = field.value.count > 56 || field.value.contains("\n")
        if isBlock {
            VStack(alignment: .leading, spacing: 4) {
                if !field.key.isEmpty {
                    keyLabel(field.key)
                }
                valueBlock(field)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                keyLabel(field.key.isEmpty ? "arguments" : field.key)
                Text(field.value.isEmpty && !field.isComplete ? "…" : field.value)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func keyLabel(_ key: String) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func valueBlock(_ field: ToolCallArgumentFormatter.Field) -> some View {
        let clipped = Self.clipped(field.value, keepingTail: !field.isComplete)
        return VStack(alignment: .leading, spacing: 4) {
            if let note = clipped.note, !field.isComplete {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(clipped.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = clipped.note, field.isComplete {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    /// While a value is being written its newest text is the interesting
    /// part, so the tail is kept; a finished value is read from the start.
    private static func clipped(
        _ value: String,
        keepingTail: Bool
    ) -> (text: String, note: String?) {
        let hidden = value.count - visibleValueLimit
        guard hidden > 0 else { return (value, nil) }
        let count = hidden.formatted(.number)
        return keepingTail
            ? (String(value.suffix(visibleValueLimit)), "\(count) earlier characters hidden")
            : (String(value.prefix(visibleValueLimit)), "\(count) more characters not shown")
    }
}
