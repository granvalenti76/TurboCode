import SwiftUI

/// What a new Studio session shows above the composer: what Studio can do,
/// and the latest artifacts to pick up from.
///
/// The view only prepares a draft or navigates. It reads the outboxes through
/// the same library call as the Artifacts page and never starts the VM.
struct StudioHomeView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(ComposerViewModel.self) private var composer

    /// Empty until the outboxes were read, so the row appears only when there
    /// is something to pick up and the cards never jump for an empty library.
    @State private var recents: [StudioRecentArtifact] = []
    @State private var revision = 0

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("What can Studio do for you?")
                    .font(AppTypography.emptyStateTitle)
                    .foregroundStyle(.primary)

                Text("Everything runs in a sandboxed Linux VM. Nothing reaches your Mac until you approve it.")
                    .font(AppTypography.emptyStateSubtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !recents.isEmpty {
                recentSection
            }

            HStack(alignment: .top, spacing: 10) {
                ForEach(StudioHomeContent.suggestions) { suggestion in
                    StudioSuggestionCard(suggestion: suggestion) {
                        composer.messageText = StudioHomeContent.draft(
                            afterChoosing: suggestion,
                            current: composer.messageText
                        )
                    }
                }
            }

            connectorRow
        }
        // Other sessions keep working while this one is still empty; reload
        // when a turn ends so their new files show up here too.
        .task(id: chatStore.busy) {
            recents = StudioHomeContent.recentArtifacts(in: await chatStore.coworkArtifactLibrary())
            revision += 1
        }
    }

    /// The connectors a Studio session may use, as switches for the session
    /// about to start, so enabling one does not need a trip to Connectors.
    @ViewBuilder
    private var connectorRow: some View {
        let connectors = MCPConnectorCatalog.all.filter { $0.domains.contains(.cowork) }
        if !connectors.isEmpty {
            HStack(spacing: 8) {
                Text("Connectors")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                ForEach(connectors) { connector in
                    Toggle(isOn: Binding(
                        get: { chatStore.activeConversation?.connectors.contains(connector.id) == true },
                        set: { enabled in Task { await chatStore.setConnector(connector.id, enabled: enabled) } }
                    )) {
                        Label(connector.name, systemImage: connector.systemImage)
                            .font(AppTypography.metadata)
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .disabled(chatStore.busy)
                    .help(connector.summary)
                    .accessibilityHint("Turns the connector on or off for this session")
                }
                Button("All connectors") { chatStore.setRoute(.connectors) }
                    .buttonStyle(.link)
                    .font(AppTypography.metadata)
                Spacer(minLength: 0)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent artifacts")
                    .font(AppTypography.controlEmphasized)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("All artifacts") { chatStore.setRoute(.artifacts) }
                    .buttonStyle(.link)
                    .font(AppTypography.metadata)
            }
            HStack(spacing: 10) {
                ForEach(recents) { recent in
                    StudioRecentArtifactRow(recent: recent, revision: revision) {
                        Task {
                            await chatStore.showCoworkArtifact(recent.artifact.id, inSession: recent.sessionID)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Capability card

private struct StudioSuggestionCard: View {
    let suggestion: StudioHomeSuggestion
    let choose: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: suggestion.systemImage)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 20)
                Text(suggestion.title)
                    .font(AppTypography.controlEmphasized)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(suggestion.subtitle)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .studioHomeTile(isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(suggestion.title). \(suggestion.subtitle)")
        .accessibilityHint("Starts a draft in the message field")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Recent artifact

private struct StudioRecentArtifactRow: View {
    let recent: StudioRecentArtifact
    let revision: Int
    let open: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                CoworkArtifactThumbnailView(
                    artifact: recent.artifact,
                    fileURL: CoworkArtifactCatalog.fileURL(for: recent.artifact, in: recent.outbox),
                    revision: revision,
                    symbolSize: 16,
                    cornerRadius: 6
                )
                .frame(width: 52, height: 39)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recent.artifact.name)
                        .font(AppTypography.controlEmphasized)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(recent.sessionTitle)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioHomeTile(isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(recent.artifact.relativePath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recent.artifact.name), from \(recent.sessionTitle)")
        .accessibilityHint("Opens the session with this artifact")
        .accessibilityAddTraits(.isButton)
    }
}

private extension View {
    /// The shared look of the home tiles: the same hover outline as the
    /// library's cards, so the two artifact surfaces read as one.
    func studioHomeTile(isHovered: Bool) -> some View {
        background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isHovered ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.separator),
                    lineWidth: isHovered ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
