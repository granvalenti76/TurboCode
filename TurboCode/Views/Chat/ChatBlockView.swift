import SwiftUI

// MARK: - ChatBlockView — renders a single message block

/// Matches Kun's block types: user, assistant, reasoning, tool, approval, review, compaction.
/// Each block kind gets its own visual treatment following Kun's design language.
struct ChatBlockView: View {
    let block: ChatBlock
    @State private var isEditing = false
    @State private var editText: String = ""

    var body: some View {
        switch block.kind {
        case .user:
            userBubble
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
                    FormattedText(block.text)
                        .font(.system(size: 14))
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
                FormattedText(block.text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let model = block.model {
                    ModelBadgeView(model: model, providerId: block.providerId)
                }
            }

            Spacer()
        }
        .padding(8)
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

                Text(block.text)
                    .font(.system(size: 12))
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
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(block.text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var approvalBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.orange)
            Text("Approval required")
                .font(.system(size: 12))
            Spacer()
            Button("Approve") {}
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Reject") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                .font(.system(size: 8))
            Text(displayName)
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundStyle(.tertiary)
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

// MARK: - FormattedText — inline markdown + code blocks + newline preservation

/// Renders model output with:
/// - Code blocks (triple backticks) in monospace with dark background
/// - Inline markdown (bold, italic, inline code) via AttributedString
/// - Single newlines preserved as line breaks, double newlines as paragraphs
struct FormattedText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        let segments = splitCodeBlocks(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(segments.indices, id: \.self) { index in
                if segments[index].isCode {
                    codeBlock(segments[index].content)
                } else {
                    inlineText(segments[index].content)
                }
            }
        }
    }

    // MARK: - Code Block

    private func codeBlock(_ content: String) -> some View {
        ScrollView(.horizontal) {
            Text(content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Inline Text (markdown)

    private func inlineText(_ content: String) -> some View {
        // Split into inline code segments and regular text
        let segments = splitInlineCode(content)
        var combined = AttributedString()

        for segment in segments {
            if segment.isCode {
                // Inline code with monospace
                var code = AttributedString(segment.content)
                code.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                combined += code
            } else {
                // Parse markdown on the non-code text
                if let parsed = try? AttributedString(markdown: segment.content, options: .init(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )) {
                    combined += parsed
                } else {
                    combined += AttributedString(segment.content)
                }
            }
        }

        return Text(combined)
            .font(.system(size: 14))
    }

    // MARK: - Splitting

    /// Splits text by triple-backtick code blocks, preserving non-code segments.
    private func splitCodeBlocks(_ input: String) -> [(content: String, isCode: Bool)] {
        var result: [(String, Bool)] = []
        var remaining = input[...]
        while let start = remaining.range(of: "```") {
            // Text before this code block
            if start.lowerBound > remaining.startIndex {
                result.append((String(remaining[remaining.startIndex..<start.lowerBound]), false))
            }
            remaining = remaining[start.upperBound...]
            if let end = remaining.range(of: "```") {
                // Skip optional language tag (first line of code block)
                var codeContent = String(remaining[..<end.lowerBound])
                if let newline = codeContent.firstIndex(of: "\n") {
                    codeContent = String(codeContent[codeContent.index(after: newline)...])
                }
                result.append((codeContent, true))
                remaining = remaining[end.upperBound...]
            } else {
                // Unclosed code block — treat rest as code
                result.append((String(remaining), true))
                remaining = remaining[remaining.endIndex...]
                break
            }
        }
        if !remaining.isEmpty {
            result.append((String(remaining), false))
        }
        if result.isEmpty { result = [(input, false)] }
        return result
    }

    /// Splits inline text by single backtick code spans.
    private func splitInlineCode(_ input: String) -> [(content: String, isCode: Bool)] {
        var result: [(String, Bool)] = []
        var remaining = input[...]
        while let start = remaining.range(of: "`") {
            if start.lowerBound > remaining.startIndex {
                result.append((String(remaining[remaining.startIndex..<start.lowerBound]), false))
            }
            remaining = remaining[start.upperBound...]
            if let end = remaining.range(of: "`") {
                result.append((String(remaining[..<end.lowerBound]), true))
                remaining = remaining[end.upperBound...]
            } else {
                result.append((String(remaining), false))
                remaining = remaining[remaining.endIndex...]
                break
            }
        }
        if !remaining.isEmpty {
            result.append((String(remaining), false))
        }
        if result.isEmpty { result = [(input, false)] }
        return result
    }
}
