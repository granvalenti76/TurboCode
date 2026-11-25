import SwiftUI

/// The agent's name and icon as the sidebar header shows them.
///
/// Without a symbol it is the plain name, exactly the header TurboCode had
/// before the setting existed.
struct AgentIdentityLabel: View {
    let identity: AgentIdentity

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = identity.symbol {
                AgentIdentityTile(symbol: symbol, tint: identity.tint, size: 22)
            }
            Text(identity.displayName)
                .font(AppTypography.sidebarHeader)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A rounded tile in the chosen color with a white symbol, the same shape
/// System Settings uses for its section icons.
struct AgentIdentityTile: View {
    let symbol: String
    let tint: AgentIdentity.Tint
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

extension AgentIdentity.Tint {
    var color: Color {
        switch self {
        case .accent: .accentColor
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        case .graphite: .gray
        }
    }

    var title: String {
        switch self {
        case .accent: "Accent"
        case .graphite: "Graphite"
        default: rawValue.capitalized
        }
    }
}

/// Settings › General › Agent: the name the model answers to and the icon
/// beside it in the sidebar.
///
/// The name is committed on Return or when the field loses focus, never per
/// keystroke: each commit changes the prompt and rebuilds the session once.
struct AgentIdentitySection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        Section {
            TextField(text: $nameDraft, prompt: Text(AgentIdentity.defaultName)) {
                Text("Name")
                Text("What the model calls itself. The app is still TurboCode.")
            }
            .focused($nameFocused)
            .onSubmit(commitName)
            .onChange(of: nameFocused) { _, focused in
                if !focused { commitName() }
            }

            Picker("Icon", selection: Binding(
                get: { settings.agentIdentity.symbol },
                set: { symbol in update { $0.symbol = symbol } }
            )) {
                Text("None").tag(String?.none)
                Divider()
                ForEach(AgentIdentity.symbolChoices, id: \.self) { symbol in
                    Label(symbol, systemImage: symbol)
                        .labelStyle(.iconOnly)
                        .tag(Optional(symbol))
                }
            }

            Picker("Color", selection: Binding(
                get: { settings.agentIdentity.tint },
                set: { tint in update { $0.tint = tint } }
            )) {
                ForEach(AgentIdentity.Tint.allCases, id: \.self) { tint in
                    Text(tint.title).tag(tint)
                }
            }
            .disabled(settings.agentIdentity.symbol == nil)

            LabeledContent("Sidebar") {
                AgentIdentityLabel(identity: settings.agentIdentity)
            }
        } header: {
            Text("Agent")
        }
        .onAppear { nameDraft = settings.agentIdentity.name }
    }

    /// Applies an icon or color change. Those only change the sidebar, so
    /// the prompts are not reloaded.
    private func update(_ change: (inout AgentIdentity) -> Void) {
        var identity = settings.agentIdentity
        change(&identity)
        settings.agentIdentity = identity
    }

    private func commitName() {
        var identity = settings.agentIdentity
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        identity.name = trimmed.isEmpty ? AgentIdentity.defaultName : trimmed
        nameDraft = identity.displayName
        identity.name = identity.displayName
        guard identity != settings.agentIdentity else { return }
        settings.agentIdentity = identity
        // The name is in the Identity area: rebuild the session once.
        Task { await chatStore.reloadSystemPrompts() }
    }
}
