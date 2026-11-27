import SwiftUI

/// The connectors a new session of `domain` may use, as switches above the
/// first message, so enabling one does not need a trip to Connectors and back
/// to a new chat. Shared by the Studio and Coding home views.
struct HomeConnectorRow: View {
    @Environment(ChatStore.self) private var chatStore

    let domain: SessionDomain

    var body: some View {
        let connectors = MCPConnectorCatalog.all.filter { $0.domains.contains(domain) }
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
                    // Flipping a connector rebuilds the session, which would
                    // cut a running turn.
                    .disabled(chatStore.busy)
                    .help(connector.summary)
                    .accessibilityHint("Turns the connector on or off for this session")
                }
                Button("All connectors") { chatStore.setRoute(.connectors) }
                    .buttonStyle(.link)
                    // The link style defaults to system blue; keep links on the app accent.
                    .tint(.accentColor)
                    .font(AppTypography.metadata)
                Spacer(minLength: 0)
            }
        }
    }
}
