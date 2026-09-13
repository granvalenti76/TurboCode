import AppKit
import MarkdownUI
import SwiftUI

/// Live, bounded companion to an immutable workspace-listing receipt. Its task
/// identity includes the conversation and workspace so a superseded read can
/// never publish content under a newer selection.
struct WorkspaceFilePreviewPane: View {
    let entry: WorkspaceListingEntry?
    let canUseLiveWorkspace: Bool

    @Environment(ChatStore.self) private var chatStore
    @Environment(\.chatFontSize) private var chatFontSize
    @State private var state: State = .idle
    @State private var markdownMode: MarkdownMode = .preview
    @State private var editingLineNumber: Int?
    @State private var showsDiscardConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Group {
                switch state {
                case .idle:
                    status(
                        "Select a file to preview",
                        systemImage: "doc.text.magnifyingglass"
                    )
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading preview…")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
                case .unsupported(let message):
                    status(message, systemImage: "eye.slash")
                case .failed(let message):
                    status(message, systemImage: "exclamationmark.triangle")
                case .loaded(let preview):
                    document(preview)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 340)

            if let entry {
                Divider()
                if isReviewingMarkdown,
                   !workspaceReviewComments(for: entry).isEmpty {
                    reviewBar(for: entry)
                } else {
                    actions(for: entry)
                }
            }
        }
        .task(id: loadKey) {
            await load()
        }
        .confirmationDialog(
            "Discard review comments for this file?",
            isPresented: $showsDiscardConfirmation
        ) {
            Button("Discard Comments", role: .destructive) {
                guard let entry else { return }
                editingLineNumber = nil
                chatStore.discardWorkspaceFileReviewComments(
                    relativePath: entry.relativePath
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These comments have not been sent to the model.")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: entry.map(iconName(for:)) ?? "doc.text")
                .foregroundStyle(entry.map(iconColor(for:)) ?? Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry?.name ?? "Preview")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let entry {
                    Text("\(entryDetail(entry)) · Current file content")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if case .loaded(let preview) = state,
               preview.kind == .markdown {
                Picker("Markdown view", selection: $markdownMode) {
                    Label("Preview", systemImage: "doc.richtext")
                        .tag(MarkdownMode.preview)
                    Label("Review", systemImage: "text.alignleft")
                        .tag(MarkdownMode.review)
                }
                .labelsHidden()
                .labelStyle(.iconOnly)
                .pickerStyle(.segmented)
                .frame(width: 76)
                .help("Choose rendered preview or line review")
                .accessibilityLabel("Markdown view")
            }

            if let entry, entry.kind == .file {
                Button {
                    open(entry)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!canUseLiveWorkspace)
                .help("Open in the default app")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func status(_ message: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label("Preview", systemImage: systemImage)
        } description: {
            Text(message)
        }
    }

    @ViewBuilder
    private func document(_ preview: WorkspaceFilePreview) -> some View {
        if preview.kind == .markdown, markdownMode == .review {
            markdownReview(preview)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if preview.isTruncated {
                        partialPreviewBanner(preview)
                    }

                    if let editorialTitle = preview.editorialTitle,
                       !editorialTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(editorialTitle)
                            .font(.system(size: 17, weight: .semibold))
                    }

                    switch preview.kind {
                    case .markdown:
                        Markdown(preview.content)
                            .markdownTheme(AppTypography.chatMarkdownTheme(size: documentFontSize))
                            .textSelection(.enabled)
                    case .plainText:
                        Text(preview.content)
                            .font(.system(size: documentFontSize))
                            .textSelection(.enabled)
                    case .sourceCode:
                        sourceCode(preview.content)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
        }
    }

    private func partialPreviewBanner(_ preview: WorkspaceFilePreview) -> some View {
        Label {
            Text(partialPreviewLabel(preview))
        } icon: {
            Image(systemName: "text.page.badge.magnifyingglass")
        }
        .font(AppTypography.metadata)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Color.accentColor.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    /// The review canvas deliberately reuses the Git inspector's row and
    /// comment editor so hover, gutter geometry, and keyboard behavior cannot
    /// drift into a second competing interaction.
    private func markdownReview(_ preview: WorkspaceFilePreview) -> some View {
        let lines = reviewLines(for: preview)
        let gutterWidth = InspectorDiffLayout.gutterWidth(for: lines)
        let minimumWidth = InspectorDiffLayout.minimumContentWidth(
            for: lines,
            gutterWidth: gutterWidth
        )
        return VStack(spacing: 0) {
            if preview.isTruncated {
                partialPreviewBanner(preview)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }

            GeometryReader { geometry in
                let contentWidth = max(geometry.size.width, minimumWidth)
                // Long Markdown lines may widen the scrolling code canvas, but
                // the comment composer must remain a compact, viewport-sized card.
                let commentEditorWidth = min(geometry.size.width, 520)
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            markdownReviewRow(
                                index: index,
                                line: line,
                                lines: lines,
                                gutterWidth: gutterWidth,
                                contentWidth: contentWidth,
                                commentEditorWidth: commentEditorWidth,
                                relativePath: preview.relativePath
                            )
                        }
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(width: contentWidth, alignment: .leading)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    @ViewBuilder
    private func markdownReviewRow(
        index: Int,
        line: DiffLine,
        lines: [DiffLine],
        gutterWidth: CGFloat,
        contentWidth: CGFloat,
        commentEditorWidth: CGFloat,
        relativePath: String
    ) -> some View {
        if let anchor = ReviewLineAnchor.make(
            filePath: relativePath,
            lineIndex: index,
            lines: lines,
            origin: .workspaceFile
        ) {
            let comment = workspaceReviewComment(matching: anchor)
            VStack(alignment: .leading, spacing: 0) {
                DiffLineView(
                    line: line,
                    tokens: [],
                    gutterWidth: gutterWidth,
                    hasComment: comment != nil,
                    isEditing: editingLineNumber == anchor.lineNumber,
                    onRequestComment: { editingLineNumber = anchor.lineNumber }
                )
                .frame(width: contentWidth, alignment: .leading)

                if editingLineNumber == anchor.lineNumber {
                    ReviewCommentEditor(
                        anchor: anchor,
                        existingComment: comment,
                        gutterWidth: gutterWidth,
                        onCancel: { editingLineNumber = nil },
                        onSave: { body in
                            _ = chatStore.upsertReviewComment(
                                id: comment?.id,
                                anchor: anchor,
                                body: body
                            )
                            editingLineNumber = nil
                        },
                        onRemove: comment.map { existing in
                            {
                                chatStore.removeReviewComment(existing.id)
                                editingLineNumber = nil
                            }
                        }
                    )
                    .frame(width: commentEditorWidth, alignment: .leading)
                }
            }
        }
    }

    private func reviewLines(for preview: WorkspaceFilePreview) -> [DiffLine] {
        preview.content.components(separatedBy: "\n").enumerated().map { index, line in
            let lineNumber = preview.contentStartLine + index
            return DiffLine(
                oldLineNumber: lineNumber,
                newLineNumber: lineNumber,
                content: line,
                type: .context
            )
        }
    }

    private func workspaceReviewComment(
        matching anchor: ReviewLineAnchor
    ) -> ReviewComment? {
        chatStore.workspaceFileReviewComments(relativePath: anchor.filePath).first {
            !$0.isOutdated
                && $0.anchor.lineNumber == anchor.lineNumber
                && $0.anchor.content == anchor.content
        }
    }

    /// Reuses the inspector lexer so source previews and diff review agree on
    /// Swift token boundaries, including nested comments and multiline strings.
    @ViewBuilder
    private func sourceCode(_ content: String) -> some View {
        ScrollView(.horizontal) {
            Text(highlightedSource(content))
                .font(.system(size: sourceFontSize, design: .monospaced))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func highlightedSource(_ content: String) -> AttributedString {
        guard let path = entry?.relativePath,
              InspectorFilePresentation.supportsSyntaxHighlighting(path) else {
            return AttributedString(content)
        }

        let lines = content.components(separatedBy: "\n")
        let tokenLines = InspectorSyntaxHighlighter.swiftTokens(for: lines)
        var result = AttributedString()
        for (lineIndex, tokens) in tokenLines.enumerated() {
            for token in tokens {
                var segment = AttributedString(token.text)
                segment.foregroundColor = syntaxColor(token.kind)
                result.append(segment)
            }
            if lineIndex < tokenLines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private func syntaxColor(_ kind: InspectorSyntaxTokenKind) -> Color {
        switch kind {
        case .plain: Color(nsColor: .labelColor).opacity(0.86)
        case .keyword: Color(nsColor: .systemPurple)
        case .type: Color(nsColor: .systemTeal)
        case .attribute: Color(nsColor: .systemPink)
        case .number: Color(nsColor: .systemBlue)
        case .string: Color(nsColor: .systemRed)
        case .comment: Color(nsColor: .secondaryLabelColor)
        }
    }

    private var documentFontSize: CGFloat {
        min(max(chatFontSize, 12), 15)
    }

    private var sourceFontSize: CGFloat {
        min(max(chatFontSize - 1, 11), 13)
    }

    private func partialPreviewLabel(_ preview: WorkspaceFilePreview) -> String {
        let shown = ByteCountFormatter.string(
            fromByteCount: Int64(preview.previewedByteCount),
            countStyle: .file
        )
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(preview.sizeBytes),
            countStyle: .file
        )
        return "Partial preview · first \(shown) of \(total)"
    }

    private func actions(for entry: WorkspaceListingEntry) -> some View {
        HStack(spacing: 10) {
            Text("Current file content")
                .italic()
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            if case .loaded(let preview) = state,
               preview.kind == .markdown {
                Button {
                    if preview.isEditorialDraft {
                        chatStore.presentEditorialDesk(draftRelativePath: entry.relativePath)
                    } else {
                        chatStore.presentEditorialDesk(importingMarkdown: entry.relativePath)
                    }
                } label: {
                    Label(
                        preview.isEditorialDraft ? "Open in Editorial Desk" : "Bring to Editorial Desk",
                        systemImage: "square.and.pencil"
                    )
                }
                .disabled(!canUseLiveWorkspace)
            }

            Button {
                openInFinder(entry)
            } label: {
                Label("Open in Finder", systemImage: "arrow.up.forward.square")
            }
            .disabled(!canUseLiveWorkspace)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(AppTypography.metadata)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func reviewBar(for entry: WorkspaceListingEntry) -> some View {
        let comments = workspaceReviewComments(for: entry)
        let outdatedCount = comments.count(where: \.isOutdated)
        return HStack(spacing: 10) {
            Label(
                "\(comments.count) \(comments.count == 1 ? "comment" : "comments")",
                systemImage: "text.bubble"
            )
            .font(.system(size: 11.5, weight: .medium))

            if outdatedCount > 0 {
                Text("\(outdatedCount) outdated")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 8)

            Button("Discard") {
                showsDiscardConfirmation = true
            }
            .buttonStyle(.borderless)
            .disabled(chatStore.busy)

            Button("Send Review") {
                editingLineNumber = nil
                Task {
                    await chatStore.sendWorkspaceFileReviewComments(
                        relativePath: entry.relativePath
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(
                !chatStore.canSendWorkspaceFileReviewComments(
                    relativePath: entry.relativePath
                )
            )
            .help(
                outdatedCount > 0
                    ? "Refresh or remove outdated comments before sending"
                    : "Send this file's review comments as one request"
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func workspaceReviewComments(
        for entry: WorkspaceListingEntry
    ) -> [ReviewComment] {
        chatStore.workspaceFileReviewComments(relativePath: entry.relativePath)
    }

    private var isReviewingMarkdown: Bool {
        guard case .loaded(let preview) = state else { return false }
        return preview.kind == .markdown && markdownMode == .review
    }

    private func open(_ entry: WorkspaceListingEntry) {
        guard canUseLiveWorkspace,
              let url = resolvedURL(for: entry) else { return }
        NSWorkspace.shared.open(url)
    }

    private var loadKey: String {
        [
            chatStore.activeThreadId ?? "no-thread",
            chatStore.workspaceRoot,
            entry?.id ?? "no-selection",
            entry?.modifiedAt ?? ""
        ].joined(separator: "|")
    }

    @MainActor
    private func load() async {
        editingLineNumber = nil
        guard let entry else {
            state = .idle
            return
        }
        guard canUseLiveWorkspace else {
            state = .failed(
                "This receipt is not associated with the active workspace. Live file actions are unavailable."
            )
            return
        }
        guard entry.kind == .file else {
            state = .unsupported(
                entry.kind == .directory
                    ? "Folders do not have a document preview."
                    : "Symbolic links are not previewed from historical receipts."
            )
            return
        }

        let requestedEntryID = entry.id
        let requestedThreadID = chatStore.activeThreadId
        let requestedWorkspaceRoot = chatStore.workspaceRoot
        state = .loading
        do {
            let preview = try await chatStore.workspaceFilePreview(
                relativePath: entry.relativePath
            )
            guard !Task.isCancelled,
                  self.entry?.id == requestedEntryID,
                  chatStore.activeThreadId == requestedThreadID,
                  chatStore.workspaceRoot == requestedWorkspaceRoot else { return }
            if preview.kind == .markdown {
                chatStore.reconcileWorkspaceFileReview(
                    relativePath: preview.relativePath,
                    lines: reviewLines(for: preview)
                )
            }
            state = .loaded(preview)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  self.entry?.id == requestedEntryID,
                  chatStore.activeThreadId == requestedThreadID,
                  chatStore.workspaceRoot == requestedWorkspaceRoot else { return }
            if let previewError = error as? WorkspaceFilePreviewError,
               case .unsupportedFormat = previewError {
                state = .unsupported(error.localizedDescription)
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func openInFinder(_ entry: WorkspaceListingEntry) {
        guard canUseLiveWorkspace,
              let url = resolvedURL(for: entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func resolvedURL(for entry: WorkspaceListingEntry) -> URL? {
        try? WorkspacePathResolver.resolve(
            entry.relativePath,
            within: chatStore.workspaceRoot
        )
    }

    private func entryDetail(_ entry: WorkspaceListingEntry) -> String {
        switch entry.kind {
        case .directory:
            return "Folder"
        case .symbolicLink:
            return "Link"
        case .file:
            let type = fileTypeLabel(for: entry)
            guard let sizeBytes = entry.sizeBytes else { return type }
            return "\(type) · \(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))"
        }
    }

    private func fileTypeLabel(for entry: WorkspaceListingEntry) -> String {
        switch entry.fileExtension {
        case "swift": "Swift"
        case "md": "Markdown"
        case "txt": "Plain Text"
        case "json": "JSON"
        case "plist": "Property List"
        case "yaml", "yml": "YAML"
        default: entry.fileExtension?.uppercased() ?? "File"
        }
    }

    private func iconName(for entry: WorkspaceListingEntry) -> String {
        switch entry.kind {
        case .directory: return "folder.fill"
        case .symbolicLink: return "link"
        case .file:
            switch entry.fileExtension {
            case "swift": return "swift"
            case "xcodeproj", "xcworkspace": return "hammer.fill"
            case "md", "txt": return "doc.text.fill"
            case "json", "plist", "yaml", "yml": return "curlybraces"
            case "png", "jpg", "jpeg", "heic", "svg": return "photo.fill"
            default: return "doc.fill"
            }
        }
    }

    private func iconColor(for entry: WorkspaceListingEntry) -> Color {
        switch entry.kind {
        case .directory: return .blue
        case .symbolicLink: return .purple
        case .file where entry.fileExtension == "swift": return .orange
        case .file: return .secondary
        }
    }

    private enum State {
        case idle
        case loading
        case loaded(WorkspaceFilePreview)
        case unsupported(String)
        case failed(String)
    }

    private enum MarkdownMode: Hashable {
        case preview
        case review
    }
}
