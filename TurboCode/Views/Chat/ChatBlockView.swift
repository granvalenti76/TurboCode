import SwiftUI
import MarkdownUI

// MARK: - ChatBlockView — renders a single message block

/// Matches Kun's block types: user, assistant, reasoning, tool, approval, review, compaction.
/// Each block kind gets its own visual treatment following Kun's design language.
struct ChatBlockView: View {
    let block: ChatBlock
    @Environment(\.chatFontSize) private var chatFontSize
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
        case .gitStatus:
            if let status = block.gitStatus {
                GitStatusWidget(status: status)
            }
        case .productGuide:
            ProductGuideWidget(block: block)
        case .workspaceListing:
            if let listing = block.workspaceListing {
                WorkspaceListingWidget(blockID: block.id, listing: listing)
            }
        }
    }

    // MARK: - User Bubble (editable, right-aligned)

    private var userBubble: some View {
        HStack {
            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(block.text)
                    .font(AppTypography.chatBody(size: max(13, chatFontSize - 1)))
                    .foregroundStyle(AppTypography.chatForeground)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    // A softened rectangle distinguishes prompts from pills
                    // while retaining the approachable native card treatment.
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(block.text, forType: .string)
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

    // MARK: - Assistant Bubble (left-aligned)

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Markdown(ChatMarkdownPresentation.cleaned(visibleAssistantText))
                .markdownTheme(AppTypography.chatMarkdownTheme(size: chatFontSize))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !visibleAssistantText.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        copyAssistantResponse()
                    } label: {
                        Image(systemName: didCopyAssistantResponse ? "checkmark" : "square.on.square")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(didCopyAssistantResponse ? Color.green : Color.secondary.opacity(0.72))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHoveringAssistantResponse || didCopyAssistantResponse ? 1 : 0)
                    .allowsHitTesting(isHoveringAssistantResponse)
                    .animation(.easeOut(duration: 0.16), value: isHoveringAssistantResponse)
                    .help(didCopyAssistantResponse ? "Copied" : "Copy response")
                    .accessibilityLabel(didCopyAssistantResponse ? "Response copied" : "Copy response")

                    Text(block.createdAt, format: .dateTime.hour().minute())
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 1)
            }
        }
        .frame(maxWidth: 1040, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { isHovering in
            isHoveringAssistantResponse = isHovering
        }
    }
    
    // MARK: - Reasoning Block

    private var reasoningBlock: some View {
        ReasoningDisclosure(
            text: block.text,
            isLive: false,
            textSize: max(12, chatFontSize - 2)
        )
    }

    // MARK: - Placeholders

    private var toolBlockPlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
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
            // Legacy review blocks have no immutable receipt to open. Modern
            // edit and Git widgets expose their own functional Review actions.
            Text("Legacy event")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var compactionNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .background(.tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("Context compacted")
                    .font(.subheadline.weight(.semibold))
                Text(block.text.contains("local Llama")
                     ? "Earlier tool chatter was summarized so the local Llama model can continue with the essential context."
                     : "Earlier tool chatter was summarized so the on-device model can continue with the essential context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 760, alignment: .leading)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.tint.opacity(0.16), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
