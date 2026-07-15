import SwiftUI
import MarkdownUI

// MARK: - ChatBlockView — renders a single message block

/// Matches Kun's block types: user, assistant, reasoning, tool, approval, review, compaction.
/// Each block kind gets its own visual treatment following Kun's design language.
struct ChatBlockView: View {
    let block: ChatBlock
    @Environment(\.chatFontSize) private var chatFontSize
    @State private var isEditing = false
    @State private var editText: String = ""
    @State private var didCopyAssistantResponse = false
    @State private var isHoveringAssistantResponse = false

    var body: some View {
        switch block.kind {
        case .user:
            if let event = internalActionEvent {
                internalActionRow(icon: event.icon, text: event.text)
            } else {
                userBubble
            }
        case .assistant:
            assistantBubble
        case .reasoning:
            reasoningBlock
        case .tool:
            toolBlockPlaceholder
        case .approval:
            approvalBanner
        case .review:
            reviewBanner
        case .compaction:
            compactionNotice
        case .diffPatch:
            if let patch = block.diffPatch {
                DiffPatchWidget(blockID: block.id, patch: patch)
            }
        case .gitCommit:
            if let receipt = block.gitCommit {
                GitCommitWidget(blockID: block.id, receipt: receipt)
            }
        case .productGuide:
            ProductGuideWidget(block: block)
        }
    }

    // MARK: - User Bubble (editable, right-aligned)

    private var userBubble: some View {
        HStack {
            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if isEditing {
                    editView
                } else {
                    Text(block.text)
                        .font(AppTypography.chatBody(size: chatFontSize))
                        .foregroundStyle(AppTypography.chatForeground)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                        .contextMenu {
                            Button("Edit") {
                                editText = block.text
                                isEditing = true
                            }
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(block.text, forType: .string)
                            }
                        }
                }

                // Model badge
                if let model = block.model {
                    ModelBadgeView(model: model, providerId: block.providerId)
                }
            }
            .frame(maxWidth: 600, alignment: .trailing)
        }
    }

    // MARK: - Edit View

    private var editView: some View {
        VStack(spacing: 8) {
            TextEditor(text: $editText)
                .font(.system(size: 14))
                .frame(minHeight: 60)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button("Cancel") { isEditing = false }
                    .buttonStyle(.borderless)

                Spacer()

                Button("Resend") {
                    // TODO: rewind & resend
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Assistant Bubble (left-aligned)

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Markdown(visibleAssistantText)
                    .markdownTheme(AppTypography.chatMarkdownTheme(size: chatFontSize))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                if !visibleAssistantText.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            copyAssistantResponse()
                        } label: {
                            Image(systemName: didCopyAssistantResponse ? "checkmark" : "square.on.square")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(didCopyAssistantResponse ? Color.green : Color.secondary.opacity(0.72))
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .opacity(isHoveringAssistantResponse || didCopyAssistantResponse ? 1 : 0)
                        .allowsHitTesting(isHoveringAssistantResponse)
                        .animation(.easeOut(duration: 0.16), value: isHoveringAssistantResponse)
                        .help(didCopyAssistantResponse ? "Copied" : "Copy response")
                        .accessibilityLabel(didCopyAssistantResponse ? "Response copied" : "Copy response")

                        Text(block.createdAt, format: .dateTime.hour().minute())
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { isHovering in
            isHoveringAssistantResponse = isHovering
        }
    }
    
    // MARK: - Reasoning Block

    private var reasoningBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("Reasoning")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)

                Text(formattedText(block.text))
                    .font(.system(size: max(12, chatFontSize - 2)))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.orange.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Placeholders

    private var toolBlockPlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(block.text)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func internalActionRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var internalActionEvent: (icon: String, text: String)? {
        let approved = block.text.hasPrefix("[User approved tool action]")
        let rejected = block.text.hasPrefix("[User rejected tool action:")
        guard approved || rejected else { return nil }

        let values = Dictionary(uniqueKeysWithValues: block.text
            .components(separatedBy: .newlines)
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                return (
                    String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            })

        let operation = values["Operation"] ?? "action"
        let path = values["Path"].map { URL(fileURLWithPath: $0).lastPathComponent }
        let action = compactAction(operation: operation, item: path)
        return approved
            ? ("checkmark.circle", "Allowed: \(action)")
            : ("xmark.circle", "Denied: \(action)")
    }

    private func compactAction(operation: String, item: String?) -> String {
        let target = item ?? "item"
        switch operation {
        case "createDirectory": return "Create \(target)"
        case "write": return "Write \(target)"
        case "append": return "Update \(target)"
        case "copy": return "Copy \(target)"
        case "move": return "Move \(target)"
        case "delete": return "Delete \(target)"
        default: return operation.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var visibleAssistantText: String {
        let approvalKeys = Set(["approval_id", "operation", "path", "destination", "summary"])
        var isSkippingApproval = false
        var visibleLines: [String] = []

        for line in block.text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("TURBOCODE_APPROVAL_REQUIRED") {
                isSkippingApproval = true
                continue
            }
            if isSkippingApproval {
                let key = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                if trimmed.isEmpty || approvalKeys.contains(key) { continue }
                isSkippingApproval = false
            }
            visibleLines.append(line)
        }

        return visibleLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyAssistantResponse() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visibleAssistantText, forType: .string)
        didCopyAssistantResponse = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopyAssistantResponse = false
        }
    }

    private var approvalBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.orange)
            Text("Approval required")
                .font(.system(size: 12))
            Spacer()
            Text("Use the action bar below")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.orange.opacity(0.2), lineWidth: 1)
        )
    }

    private var reviewBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.blue)
            Text("Review changes")
                .font(.system(size: 12))
            Spacer()
            Button("Review") {}
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var compactionNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text("Earlier messages compacted")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

// MARK: - ModelBadgeView

struct ModelBadgeView: View {
    let model: String
    let providerId: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.system(size: 11))
            Text(displayName)
                .font(AppTypography.badge)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private var displayName: String {
        if let providerId, !providerId.isEmpty {
            return "\(providerId)/\(model)"
        }
        return model
    }
}

// MARK: - Text formatting

/// Cleans up model output: unescapes \\n, \\t then tries markdown rendering.
/// Falls back to plain AttributedString if markdown parsing fails.
/// The base font size is embedded in the AttributedString so that
/// markdown-specific fonts (bold, italic, code) are preserved.
///  DEAD CODE
func formattedText(_ input: String) -> AttributedString {
    let cleaned = input
        .replacingOccurrences(of: "\\\\", with: "\u{1D}")
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\\t", with: "\t")
        .replacingOccurrences(of: "\\r", with: "\r")
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\u{1D}", with: "\\\\")
        .replacingOccurrences(of: "\t", with: "    ")
    // Try markdown parsing (full, for code blocks and inline formatting)
    if let parsed = try? AttributedString(
        markdown: cleaned,
        options: .init(interpretedSyntax: .full)
    ) {
        return parsed
    }
    return AttributedString(cleaned)
}
