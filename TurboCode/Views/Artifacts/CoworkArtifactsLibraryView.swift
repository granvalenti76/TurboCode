import SwiftUI

// MARK: - Cowork Artifacts Library

/// The main-view destination behind the sidebar's Artifacts item: what Cowork
/// sessions placed in `/out`, as a grid with one card per session.
///
/// A session's deliverable is usually one thing made of several files (a page
/// with its assets and screenshots), so the card shows the session's primary
/// file and counts the rest instead of giving a stylesheet the same weight as
/// the page. The flow has two steps and one way back. The grid answers "what
/// did my sessions make"; choosing a card opens the primary file at full size
/// with a Back control, a strip to reach the session's other files, and a way
/// to the session that made them. Like the
/// inspector, the library only reads the outbox folders: copying a file to
/// the Mac stays with the session's Review & Export.
struct CoworkArtifactsLibraryView: View {
    @Environment(ChatStore.self) private var chatStore

    /// `nil` until the first load, so an empty library is not announced while
    /// the outboxes are still being read.
    @State private var groups: [CoworkArtifactGroup]?
    @State private var opened: OpenedArtifact?
    @State private var revision = 0

    private struct OpenedArtifact: Equatable {
        let group: CoworkArtifactGroup
        let artifact: CoworkArtifact
    }

    private static let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 20, alignment: .top)]

    var body: some View {
        Group {
            if let opened {
                detail(opened)
            } else {
                library
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sessions keep working while the library is open; reload when a turn
        // ends so new files appear without leaving the page.
        .task(id: chatStore.busy) { await reload() }
    }

    // MARK: Grid

    private var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let groups {
                    if groups.isEmpty {
                        ContentUnavailableView(
                            "No artifacts yet",
                            systemImage: "square.stack.3d.up",
                            description: Text("Files a Studio session puts in /out appear here.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 24) {
                            ForEach(groups) { group in
                                // A group without files has nothing to show.
                                if let primary = group.primary {
                                    CoworkArtifactCard(
                                        group: group,
                                        primary: primary,
                                        fileURL: CoworkArtifactCatalog.fileURL(for: primary, in: group.outbox),
                                        revision: revision,
                                        open: { opened = OpenedArtifact(group: group, artifact: primary) },
                                        openSession: { Task { await chatStore.openThread(group.sessionID) } }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Artifacts")
                    .font(AppTypography.pageTitle)
                Text("What your Studio sessions made. Open one to preview its files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await reload() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .controlSize(.regular)
            .help("Read the session outboxes again")
        }
    }

    // MARK: Detail

    private func detail(_ opened: OpenedArtifact) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    self.opened = nil
                } label: {
                    Label("Artifacts", systemImage: "chevron.left")
                }
                .help("Back to all artifacts")
                .keyboardShortcut(.cancelAction)

                VStack(alignment: .leading, spacing: 2) {
                    Text(opened.artifact.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(opened.artifact.kind.title) · \(opened.artifact.size.formatted(.byteCount(style: .file))) · \(opened.group.sessionTitle)")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button("Show in Session") {
                    Task {
                        await chatStore.showCoworkArtifact(
                            opened.artifact.id, inSession: opened.group.sessionID
                        )
                    }
                }
                .help("Open the session with this file in the Artifacts inspector")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if let url = CoworkArtifactCatalog.fileURL(for: opened.artifact, in: opened.group.outbox) {
                CoworkArtifactPreview(
                    artifact: opened.artifact,
                    fileURL: url,
                    outbox: opened.group.outbox,
                    revision: revision
                )
            }

            if opened.group.artifacts.count > 1 {
                Divider()
                fileStrip(opened)
            }
        }
    }

    /// The session's files under the preview, primary first. The grid shows
    /// one card per session, so this strip is the only way to the other files.
    private func fileStrip(_ opened: OpenedArtifact) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(opened.group.browsingOrder) { artifact in
                    CoworkArtifactStripItem(
                        label: artifact.name,
                        isSelected: artifact == opened.artifact,
                        help: artifact.relativePath,
                        accessibilityLabel: "\(artifact.name), \(artifact.kind.title)"
                    ) {
                        CoworkArtifactThumbnailView(
                            artifact: artifact,
                            fileURL: CoworkArtifactCatalog.fileURL(for: artifact, in: opened.group.outbox),
                            outbox: opened.group.outbox,
                            revision: revision,
                            symbolSize: 17,
                            cornerRadius: 6
                        )
                    } select: {
                        self.opened = OpenedArtifact(group: opened.group, artifact: artifact)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func reload() async {
        let updated = await chatStore.coworkArtifactLibrary()
        groups = updated
        revision += 1
        // A file that no longer exists cannot stay open; return to the grid.
        // Otherwise adopt the refreshed group so the strip lists new files.
        if let current = opened {
            if let group = updated.first(where: { $0.id == current.group.id }),
               group.artifacts.contains(current.artifact) {
                opened = OpenedArtifact(group: group, artifact: current.artifact)
            } else {
                opened = nil
            }
        }
    }
}

// MARK: - Card

/// One session in the grid: a thumbnail of its primary file, the session's
/// title, and a line saying what the file is and how many files came with it.
private struct CoworkArtifactCard: View {
    let group: CoworkArtifactGroup
    let primary: CoworkArtifact
    let fileURL: URL?
    let revision: Int
    let open: () -> Void
    let openSession: () -> Void

    @State private var isHovered = false

    private var summary: String {
        let count = group.artifacts.count == 1 ? "1 file" : "\(group.artifacts.count) files"
        let date = group.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(primary.kind.title) · \(count) · \(date)"
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnailView
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.sessionTitle)
                        .font(AppTypography.controlEmphasized)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(summary)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(primary.relativePath)
        .contextMenu {
            Button("Open Session", action: openSession)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.sessionTitle), \(summary)")
        .accessibilityHint("Opens a preview of \(primary.name)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open Session", openSession)
    }

    private var thumbnailView: some View {
        CoworkArtifactThumbnailView(
            artifact: primary,
            fileURL: fileURL,
            outbox: group.outbox,
            revision: revision,
            fillsFrame: true
        )
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.separator),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            }
    }
}
