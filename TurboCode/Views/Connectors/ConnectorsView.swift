import SwiftUI

/// The built-in connectors, with a switch for the active session.
///
/// The page changes nothing but the session's list of connectors and, for
/// Safari, the existing global opt-in. Asking an app for its tools is the only
/// request it sends, so opening the page never changes anything in that app.
struct ConnectorsView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(SettingsStore.self) private var settings

    /// `nil` while an app has not answered yet.
    @State private var availability: [String: Availability] = [:]

    enum Availability: Equatable {
        case ready(toolCount: Int)
        case notRunning
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                VStack(spacing: 12) {
                    ForEach(MCPConnectorCatalog.all) { connector in
                        ConnectorCard(
                            systemImage: connector.systemImage,
                            name: connector.name,
                            summary: connector.skillResource.map {
                                "\(connector.summary) Adds the skill \($0), loaded only when a request needs it."
                            } ?? connector.summary,
                            status: status(for: connector),
                            scope: "This session",
                            isOn: sessionBinding(for: connector),
                            isEnabled: canChange(connector)
                        )
                    }
                    safariCard
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await probe() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connectors")
                    .font(AppTypography.pageTitle)
                Text("Let a session work with other apps on your Mac. A connector stays off until you turn it on for a session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Before the first message there is no session yet; the
                // switch creates it, so the choice applies to the new chat.
                Text("Session: \(chatStore.activeConversation?.title ?? "New Chat")")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            Spacer()
            Button {
                Task { await probe() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help("Check again which apps are running")
        }
    }

    // MARK: Session connectors

    private func sessionBinding(for connector: MCPConnector) -> Binding<Bool> {
        Binding(
            get: { chatStore.activeConversation?.connectors.contains(connector.id) == true },
            set: { enabled in Task { await chatStore.setConnector(connector.id, enabled: enabled) } }
        )
    }

    private func canChange(_ connector: MCPConnector) -> Bool {
        // Changing the list rebuilds the session, which would cut a running
        // turn. Without a session yet, the switch creates one in this domain.
        !chatStore.busy && connector.domains.contains(chatStore.activeDomain)
    }

    private func status(for connector: MCPConnector) -> ConnectorCard.Status {
        guard connector.domains.contains(chatStore.activeDomain) else {
            return .init(text: Self.unavailableText(in: chatStore.activeDomain), tone: .neutral)
        }
        switch availability[connector.id] {
        case nil:
            return .init(text: "Checking…", tone: .neutral)
        case .ready(let toolCount):
            return .init(text: "Running on this Mac · \(toolCount) tools", tone: .positive)
        case .notRunning:
            return .init(text: "Not running. \(connector.startHint)", tone: .attention)
        case .failed(let detail):
            return .init(text: detail, tone: .attention)
        }
    }

    private static func unavailableText(in domain: SessionDomain) -> String {
        domain == .cowork ? "Not available in Studio" : "Not available in Coding"
    }

    private func probe() async {
        for connector in MCPConnectorCatalog.all {
            let client = await MCPConnectorClients.shared.client(for: connector)
            do {
                availability[connector.id] = .ready(toolCount: try await client.listTools().count)
            } catch MCPLoopbackHTTPError.notRunning {
                availability[connector.id] = .notRunning
            } catch {
                availability[connector.id] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Safari

    /// Safari keeps its existing switch: one opt-in for every Coding session,
    /// the same value as Settings › Agents › Experimental. It is listed here
    /// so all connectors are found in one place. Studio never receives it,
    /// because browsing for the user is not what the Studio VM is for.
    private var safariCard: some View {
        let isStudio = chatStore.activeDomain == .cowork
        return ConnectorCard(
            systemImage: "safari",
            name: "Safari",
            summary: "Open pages, read them, click, and type through safaridriver.",
            status: isStudio
                ? .init(text: Self.unavailableText(in: .cowork), tone: .neutral)
                : .init(text: "Starts when the model first uses it", tone: .neutral),
            scope: "All Coding sessions",
            isOn: isStudio ? .constant(false) : Bindable(settings).agentTuning.experimental.safariMCPEnabled,
            isEnabled: !isStudio
        )
    }
}

// MARK: - Card

private struct ConnectorCard: View {
    struct Status: Equatable {
        enum Tone { case positive, attention, neutral }
        let text: String
        let tone: Tone
    }

    let systemImage: String
    let name: String
    let summary: String
    let status: Status
    /// What the switch applies to, because the two kinds of card differ.
    let scope: String
    @Binding var isOn: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 40)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.quaternary.opacity(0.6))
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Circle()
                        .fill(toneColor)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(status.text)
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Toggle(name, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!isEnabled)
                    .accessibilityLabel("\(name), \(scope)")
                Text(scope)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        }
    }

    private var toneColor: Color {
        switch status.tone {
        case .positive: .green
        case .attention: .orange
        case .neutral: .secondary
        }
    }
}
