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
                actions(for: entry)
            }
        }
        .task(id: loadKey) {
            await load()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if preview.isTruncated {
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
}
