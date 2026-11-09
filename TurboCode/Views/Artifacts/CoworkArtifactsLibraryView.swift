import SwiftUI

// MARK: - Cowork Artifacts Library

/// The main-view destination behind the sidebar's Artifacts item: every file
/// Cowork sessions placed in `/out`, as a grid grouped by session.
///
/// The flow has two steps and one way back. The grid answers "what did my
/// sessions make"; choosing a card opens that file at full size with a Back
/// control, and each group leads to the session that made it. Like the
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

    private static let columns = [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: 18, alignment: .top)]

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
                            description: Text("Files a Cowork session puts in /out appear here.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        ForEach(groups) { group in
                            section(group)
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
                    .font(.system(size: 28, weight: .semibold))
                Text("Files your Cowork sessions created. Open one to preview it.")
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

    private func section(_ group: CoworkArtifactGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.sessionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(sectionSummary(group))
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button("Open Session") {
                    Task { await chatStore.openThread(group.sessionID) }
                }
                .buttonStyle(.link)
                .font(AppTypography.control)
                .help("Go to the session that created these files")
            }

            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 20) {
                ForEach(group.artifacts) { artifact in
                    CoworkArtifactCard(
                        artifact: artifact,
                        fileURL: CoworkArtifactCatalog.fileURL(for: artifact, in: group.outbox),
                        revision: revision
                    ) {
                        opened = OpenedArtifact(group: group, artifact: artifact)
                    }
                }
            }
        }
    }

    private func sectionSummary(_ group: CoworkArtifactGroup) -> String {
        let count = group.artifacts.count == 1 ? "1 file" : "\(group.artifacts.count) files"
        return "\(count) · \(group.updatedAt.formatted(date: .abbreviated, time: .shortened))"
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
        }
    }

    private func reload() async {
        let updated = await chatStore.coworkArtifactLibrary()
        groups = updated
        revision += 1
        // A file that no longer exists cannot stay open; return to the grid.
        if let current = opened,
           updated.first(where: { $0.id == current.group.id })?.artifacts.contains(current.artifact) != true {
            opened = nil
        }
    }
}

// MARK: - Card

/// One artifact in the grid: a thumbnail of the file itself where the system
/// can make one, its name, and a one-line description.
private struct CoworkArtifactCard: View {
    let artifact: CoworkArtifact
    let fileURL: URL?
    let revision: Int
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                thumbnailView
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.name)
                        .font(AppTypography.controlEmphasized)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(artifact.kind.title) · \(artifact.size.formatted(.byteCount(style: .file)))")
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
        .help(artifact.relativePath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(artifact.name), \(artifact.kind.title)")
        .accessibilityHint("Opens a preview")
        .accessibilityAddTraits(.isButton)
    }

    private var thumbnailView: some View {
        CoworkArtifactThumbnailView(artifact: artifact, fileURL: fileURL, revision: revision)
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
