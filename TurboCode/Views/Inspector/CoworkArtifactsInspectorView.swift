import AppKit
import PDFKit
import SwiftUI
import WebKit

// MARK: - Cowork Artifacts Inspector

/// Shows the files the active Cowork session placed in `/out` and a preview
/// of the selected one, so the user can follow the work beside the chat.
///
/// The layout reads top to bottom in the order the user thinks: what this
/// session produced (title and count), which file (the list), and what it
/// looks like (the preview). The list stays visible above the preview so
/// switching file is one click and never hides what else exists.
///
/// The inspector only reads the session's outbox folder on the Mac. It never
/// copies a file into the user's folders: that remains the job of
/// Review & Export, which this view links to rather than replaces.
struct CoworkArtifactsInspectorView: View {
    @Environment(ChatStore.self) private var chatStore

    @State private var listing: CoworkArtifactListing?
    @State private var selectedID: CoworkArtifact.ID?
    /// Bumped on every reload so a preview re-reads a file the agent rewrote
    /// in place, which keeps the same path and therefore the same identity.
    @State private var revision = 0

    /// Rows beyond this scroll, so a build with many files cannot push the
    /// preview out of the panel.
    private static let maximumVisibleRows = 6
    private static let rowHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            if let listing, !listing.artifacts.isEmpty {
                header(listing)
                Divider()
                artifactList(listing)
                Divider()
                if let artifact = listing.artifacts.first(where: { $0.id == selectedID }),
                   let url = CoworkArtifactCatalog.fileURL(for: artifact, in: listing.outbox) {
                    previewTitle(artifact)
                    Divider()
                    CoworkArtifactPreview(
                        artifact: artifact,
                        fileURL: url,
                        outbox: listing.outbox,
                        revision: revision
                    )
                } else {
                    ContentUnavailableView(
                        "Select an artifact",
                        systemImage: "square.stack.3d.up",
                        description: Text("Choose a file above to preview it.")
                    )
                }
            } else if listing == nil {
                ContentUnavailableView(
                    "No Cowork session",
                    systemImage: "square.stack.3d.up",
                    description: Text("Artifacts are the files a Cowork session creates.")
                )
            } else {
                ContentUnavailableView(
                    "No artifacts yet",
                    systemImage: "square.stack.3d.up",
                    description: Text("Files the agent puts in /out appear here as it works.")
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

    // MARK: Header

    private func header(_ listing: CoworkArtifactListing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Artifacts")
                    .font(.system(size: 15, weight: .semibold))

                HStack(spacing: 6) {
                    Text(listing.artifacts.count == 1 ? "1 file" : "\(listing.artifacts.count) files")
                    Text("·")
                    Text("/out")
                        .fontDesign(.monospaced)
                    Text("·")
                    Text(totalSize(of: listing))
                }
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload the artifacts and the preview")
            .accessibilityLabel("Reload artifacts")

            // Named, not an icon: it is the one action here that leaves the
            // inspector, and the only way a file reaches the Mac.
            Button("Export…") {
                chatStore.presentCoworkExport()
            }
            .controlSize(.small)
            .help("Review the session's deliverables and copy approved files to your Mac")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: List

    private func artifactList(_ listing: CoworkArtifactListing) -> some View {
        List(listing.artifacts, selection: $selectedID) { artifact in
            HStack(spacing: 8) {
                Image(systemName: artifact.kind.symbolName)
                    .foregroundStyle(artifact.kind.tint)
                    .frame(width: 16)

                Text(artifact.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let folder = artifact.folder {
                    Text(folder)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 8)

                Text(artifact.size.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            .help(artifact.relativePath)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(artifact.name), \(artifact.kind.title)")
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, Self.rowHeight)
        .frame(height: CGFloat(min(listing.artifacts.count, Self.maximumVisibleRows)) * Self.rowHeight + 8)
    }

    // MARK: Preview title

    /// Names what the preview below shows, so the two halves of the panel
    /// read as "this file" and "its content" even when the list has scrolled.
    private func previewTitle(_ artifact: CoworkArtifact) -> some View {
        HStack(spacing: 6) {
            Text(artifact.name)
                .font(AppTypography.controlEmphasized)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("\(artifact.kind.title) · \(artifact.size.formatted(.byteCount(style: .file)))")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func totalSize(of listing: CoworkArtifactListing) -> String {
        listing.artifacts.reduce(Int64(0)) { $0 + $1.size }.formatted(.byteCount(style: .file))
    }

    private func reload() async {
        let updated = await chatStore.coworkArtifacts().map {
            CoworkArtifactListing(
                outbox: $0.outbox,
                artifacts: CoworkArtifactCatalog.displayOrdered($0.artifacts)
            )
        }
        // Compare against the same session only: after switching session the
        // previous list says nothing about what is new.
        let previous = listing?.outbox == updated?.outbox ? listing?.artifacts : nil
        selectedID = CoworkArtifactCatalog.selection(
            current: selectedID,
            previous: previous,
            updated: updated?.artifacts ?? []
        )?.id
        listing = updated
        revision += 1
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

private extension CoworkArtifact {
    /// The folder inside `/out`, shown beside the name so two files called
    /// `index.html` can be told apart. `nil` at the top level.
    var folder: String? {
        let folder = (relativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
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
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(12)
                            .accessibilityLabel(artifact.name)
                    }
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
