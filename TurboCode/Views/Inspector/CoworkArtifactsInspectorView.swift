import AppKit
import PDFKit
import SwiftUI
import WebKit

// MARK: - Cowork Artifacts Inspector

/// Shows what the active Cowork session made, beside the chat: one large
/// preview, and under it a strip of thumbnails to move between items.
///
/// The preview comes first because it is what the user opened the panel for;
/// a single thin bar names it and holds the two actions. The strip uses the
/// same thumbnails as the Artifacts library, so an item is recognizable in
/// both places. Two kinds of item appear, in this order:
///
/// - servers the agent left running in the VM, opened as a live page, because
///   a modern web build needs to be served rather than opened from a file;
/// - the files the session placed in `/out`.
///
/// The inspector only reads the session's outbox folder on the Mac. It never
/// copies a file into the user's folders: that remains the job of
/// Review & Export, which this view links to rather than replaces.
struct CoworkArtifactsInspectorView: View {
    @Environment(ChatStore.self) private var chatStore

    /// `true` when this same view is drawn over the chat for a larger
    /// preview. Only the expand control changes; the content and the strip
    /// are identical so the user does not relearn anything.
    var isExpanded = false

    @State private var listing: CoworkArtifactListing?
    @State private var livePreviews: [CoworkLivePreview] = []
    /// Bumped on every reload so a preview re-reads a file the agent rewrote
    /// in place, which keeps the same path and therefore the same identity.
    @State private var revision = 0

    /// An artifact's relative path or a live preview's ID; the two never
    /// collide. Stored per session outside the view, because the inspector is
    /// rebuilt each time it opens and must come back to the same item.
    private var selectedID: String? { chatStore.coworkArtifactSelection }

    var body: some View {
        VStack(spacing: 0) {
            if let listing, !(listing.artifacts.isEmpty && livePreviews.isEmpty) {
                if let live = livePreviews.first(where: { $0.id == selectedID }), let url = live.url {
                    titleBar(name: live.title, detail: "Live · \(live.host)")
                    Divider()
                    CoworkLiveWebView(url: url, revision: revision)
                } else if let artifact = listing.artifacts.first(where: { $0.id == selectedID }),
                          let url = CoworkArtifactCatalog.fileURL(for: artifact, in: listing.outbox) {
                    titleBar(
                        name: artifact.name,
                        detail: "\(artifact.kind.title) · \(artifact.size.formatted(.byteCount(style: .file)))"
                    )
                    Divider()
                    CoworkArtifactPreview(
                        artifact: artifact,
                        fileURL: url,
                        outbox: listing.outbox,
                        revision: revision
                    )
                } else {
                    titleBar(name: "Artifacts", detail: "")
                    Divider()
                    ContentUnavailableView(
                        "Select an artifact",
                        systemImage: "square.stack.3d.up",
                        description: Text("Choose an item below to preview it.")
                    )
                }
                Divider()
                strip(listing)
            } else if listing == nil {
                emptyState(
                    "No Studio session",
                    "Artifacts are the pages and files a Studio session creates."
                )
            } else {
                emptyState(
                    "No artifacts yet",
                    "Files the agent puts in /out and servers it leaves running appear here."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Reload when the session changes, when a turn ends, and when the
        // export review closes (it may have cleared the outbox).
        .task(id: refreshKey) { await reload() }
    }

    private var refreshKey: String {
        "\(chatStore.activeThreadId ?? "")|\(chatStore.busy)|\(chatStore.coworkExportPresentation == nil)"
    }

    /// Without items there is no title bar, so the expanded view offers its
    /// own way back; otherwise it would cover the chat with no exit.
    private func emptyState(_ title: String, _ message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "square.stack.3d.up")
        } description: {
            Text(message)
        } actions: {
            if isExpanded {
                Button("Return to Inspector") {
                    chatStore.setCoworkArtifactsExpanded(false)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Title bar

    /// The only bar above the preview: what is shown, then the two actions.
    private func titleBar(name: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(AppTypography.controlEmphasized)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload the artifacts and the preview")
            .accessibilityLabel("Reload artifacts")

            // Expanding only moves the preview over the chat; the same button
            // (or Escape) brings it back to the inspector at its previous size.
            if isExpanded {
                Button {
                    chatStore.setCoworkArtifactsExpanded(false)
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Return the preview to the inspector")
                .accessibilityLabel("Return to inspector")
            } else {
                Button {
                    chatStore.setCoworkArtifactsExpanded(true)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Show the preview in the main view")
                .accessibilityLabel("Expand preview")
            }

            // Named, not an icon: it is the one action here that leaves the
            // inspector, and the only way a file reaches the Mac.
            Button("Export…") {
                chatStore.presentCoworkExport()
            }
            .controlSize(.small)
            .disabled(listing?.artifacts.isEmpty != false)
            .help("Review the session's files and copy approved ones to your Mac")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    // MARK: Strip

    private func strip(_ listing: CoworkArtifactListing) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    // Running servers first: they are the live state of the
                    // work, while the files are what was set aside in /out.
                    ForEach(livePreviews) { live in
                        CoworkArtifactStripItem(
                            label: ":\(String(live.port))",
                            isSelected: live.id == selectedID,
                            help: "Live server in the Studio VM, \(live.host):\(String(live.port))",
                            accessibilityLabel: "\(live.title), live server"
                        ) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.quaternary.opacity(0.5))
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 17, weight: .light))
                                    .foregroundStyle(.green)
                            }
                        } select: {
                            chatStore.coworkArtifactSelection = live.id
                        }
                        .id(live.id)
                    }
                    ForEach(listing.artifacts) { artifact in
                        CoworkArtifactStripItem(
                            label: artifact.name,
                            isSelected: artifact.id == selectedID,
                            help: artifact.relativePath,
                            accessibilityLabel: "\(artifact.name), \(artifact.kind.title)"
                        ) {
                            CoworkArtifactThumbnailView(
                                artifact: artifact,
                                fileURL: CoworkArtifactCatalog.fileURL(for: artifact, in: listing.outbox),
                                revision: revision,
                                symbolSize: 17,
                                cornerRadius: 6
                            )
                        } select: {
                            chatStore.coworkArtifactSelection = artifact.id
                        }
                        .id(artifact.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            // Keep the shown item in view when the selection moves by itself,
            // for example to a file the agent just created.
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(.bar)
    }

    private func reload() async {
        let updated = await chatStore.coworkArtifacts().map {
            CoworkArtifactListing(
                outbox: $0.outbox,
                artifacts: CoworkArtifactCatalog.displayOrdered($0.artifacts)
            )
        }
        let updatedLive = await chatStore.coworkLivePreviews()
        // Compare against the same session only: after switching session, or
        // on a freshly opened inspector, the previous list says nothing about
        // what is new.
        let sameSession = listing != nil && listing?.outbox == updated?.outbox
        chatStore.coworkArtifactSelection = CoworkLivePreviewSelection.selection(
            current: selectedID,
            previousLive: sameSession ? livePreviews : nil,
            updatedLive: updatedLive,
            artifact: CoworkArtifactCatalog.selection(
                current: selectedID,
                previous: sameSession ? listing?.artifacts : nil,
                updated: updated?.artifacts ?? []
            )
        )
        listing = updated
        livePreviews = updatedLive
        revision += 1
    }
}

/// One item of a file strip: a small thumbnail with its name, ringed when it
/// is the one shown above. Shared with the library's detail view so moving
/// between a session's files looks the same in both places.
struct CoworkArtifactStripItem<Thumbnail: View>: View {
    let label: String
    let isSelected: Bool
    let help: String
    let accessibilityLabel: String
    @ViewBuilder let thumbnail: () -> Thumbnail
    let select: () -> Void

    @State private var isHovered = false

    private static var width: CGFloat { 64 }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                thumbnail()
                    .frame(width: Self.width, height: 48)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? AnyShapeStyle(Color.accentColor)
                                    : isHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.separator),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                Text(label)
                    .font(AppTypography.metadata)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: Self.width)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Presentation

extension CoworkArtifact.Kind {
    var title: String {
        switch self {
        case .webPage: "Web page"
        case .image: "Image"
        case .pdf: "PDF"
        case .text: "Text"
        case .other: "File"
        }
    }

    var symbolName: String {
        switch self {
        case .webPage: "globe"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.plaintext"
        case .other: "doc"
        }
    }

    var tint: Color {
        switch self {
        case .webPage: .blue
        case .image: .green
        case .pdf: .red
        case .text, .other: .secondary
        }
    }
}

// MARK: - Preview

/// Shared by the inspector and the Artifacts library, so a file looks the same
/// beside the chat and in the main view.
struct CoworkArtifactPreview: View {
    let artifact: CoworkArtifact
    let fileURL: URL
    let outbox: URL
    let revision: Int

    /// Enough for a source file or a data sample; larger files are cut so a
    /// big log cannot stall the inspector.
    private static let maximumTextBytes = 200_000

    var body: some View {
        Group {
            switch artifact.kind {
            case .webPage:
                CoworkArtifactWebView(fileURL: fileURL, outbox: outbox, revision: revision)
            case .image:
                if let image = NSImage(contentsOf: fileURL) {
                    // Fitted to the panel: inside a scroll view the image would
                    // keep its pixel size and show only its top-left corner.
                    // The expand control is how the user gets a larger view.
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                        .accessibilityLabel(artifact.name)
                } else {
                    unavailable("This image couldn't be read.")
                }
            case .pdf:
                CoworkArtifactPDFView(fileURL: fileURL, revision: revision)
            case .text:
                CoworkArtifactTextView(fileURL: fileURL, limit: Self.maximumTextBytes)
            case .other:
                unavailable("No preview for this file type. Use Review & Export to copy it to your Mac.")
            }
        }
        // A rewritten file keeps its path; the revision makes image and text
        // previews load it again instead of showing the previous content.
        .id("\(artifact.id)|\(revision)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ message: String) -> some View {
        ContentUnavailableView(
            artifact.name,
            systemImage: "doc",
            description: Text(message)
        )
    }
}

private struct CoworkArtifactTextView: View {
    let fileURL: URL
    let limit: Int

    @State private var text: String?
    @State private var isTruncated = false

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 8) {
                Text(text ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                if isTruncated {
                    Text("Preview shortened. Export the file to read all of it.")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .task {
            let url = fileURL
            let limit = limit
            let loaded = await Task.detached(priority: .utility) { () -> (String, Bool) in
                guard let handle = try? FileHandle(forReadingFrom: url) else {
                    return ("This file couldn't be read.", false)
                }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: limit + 1)) ?? Data()
                return (String(decoding: data.prefix(limit), as: UTF8.self), data.count > limit)
            }.value
            text = loaded.0
            isTruncated = loaded.1
        }
    }
}

private struct CoworkArtifactPDFView: NSViewRepresentable {
    let fileURL: URL
    let revision: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: fileURL)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.revision != revision || view.document?.documentURL != fileURL else { return }
        context.coordinator.revision = revision
        view.document = PDFDocument(url: fileURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator(revision: revision) }

    final class Coordinator {
        var revision: Int
        init(revision: Int) { self.revision = revision }
    }
}

/// Shows a server running in the VM. It is a plain page load of the guest's
/// address: no script bridge into the app and no persistent website data.
private struct CoworkLiveWebView: NSViewRepresentable {
    let url: URL
    let revision: Int

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        load(in: webView, coordinator: context.coordinator)
        return webView
    }

    /// Reloads when a turn ends, so the page shows what the agent just changed
    /// even when the server does not push updates itself.
    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url || context.coordinator.revision != revision else { return }
        load(in: webView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func load(in webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        coordinator.revision = revision
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    final class Coordinator {
        var loadedURL: URL?
        var revision = -1
    }
}

/// Renders an HTML artifact from the outbox.
///
/// The page was written by a model, so it gets a plain web view: no script
/// bridge into the app, no persistent website data, and file access limited
/// to the session's outbox so sibling scripts, styles, and images still load.
/// Network access is left on, because generated pages commonly load libraries
/// and fonts from a CDN and the page can reach nothing on the Mac but this
/// folder.
private struct CoworkArtifactWebView: NSViewRepresentable {
    let fileURL: URL
    let outbox: URL
    let revision: Int

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        load(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != fileURL || context.coordinator.revision != revision else { return }
        load(in: webView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func load(in webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedURL = fileURL
        coordinator.revision = revision
        webView.loadFileURL(fileURL, allowingReadAccessTo: outbox)
    }

    final class Coordinator {
        var loadedURL: URL?
        var revision = -1
    }
}
