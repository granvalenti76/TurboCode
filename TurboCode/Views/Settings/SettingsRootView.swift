import SwiftUI

// MARK: - SettingsRootView

/// The Settings window: a fixed sidebar of purpose groups and one pane per
/// `SettingsSection`.
///
/// This replaces the sidebar-adaptable `TabView`, which drew a large empty
/// title area, truncated pane names, and offered no grouping. The sidebar has
/// a fixed width and cannot collapse, so the window keeps a stable shape as
/// macOS settings windows should; the window title follows the selected pane.
struct SettingsRootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @State private var selection: SettingsSection? = .general
    @State private var agentTuningPublish: Task<Void, Never>?
    @State private var searchQuery = ""

    var body: some View {
        let current = selection ?? .general
        let results = SettingsGroup.allCases.compactMap { group -> (SettingsGroup, [SettingsSection])? in
            let sections = group.sections.filter { $0.matches(searchQuery: searchQuery) }
            return sections.isEmpty ? nil : (group, sections)
        }
        NavigationSplitView {
            List(selection: $selection) {
                // Groups without a match disappear, so the sidebar shows only
                // where the searched setting lives. The detail keeps the
                // current pane; searching never changes the selection.
                ForEach(results, id: \.0) { group, sections in
                    Section(group.title) {
                        ForEach(sections, id: \.self) { section in
                            Label {
                                Text(section.title)
                            } icon: {
                                SettingsIconTile(section: section)
                            }
                            .tag(section)
                        }
                    }
                }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                }
            }
            .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search")
            .listStyle(.sidebar)
            // The Settings window ignored navigationSplitViewColumnWidth alone
            // (fixed, then min/ideal/max) and kept the sidebar so narrow that
            // "Keyboard Shortcuts" truncated. A minimum frame on the sidebar
            // content raises the split view's own minimum, which it honors.
            .frame(minWidth: 240)
            .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane(for: current)
                // The title still names the window for the Window menu and
                // accessibility, but the toolbar does not draw it: the pane
                // header already shows it, and drawing both repeated it.
                .navigationTitle(current.title)
                .toolbar(removing: .title)
                // Panes link to each other (Permissions → Studio) through
                // this action instead of owning the selection.
                .environment(\.openSettingsSection, OpenSettingsSectionAction { selection = $0 })
        }
        // The Settings scene opens at the ideal size; the minimum keeps the
        // fixed sidebar plus a readable pane.
        .frame(minWidth: 820, idealWidth: 940, minHeight: 560, idealHeight: 700)
        .onChange(of: settings.agentTuning) { _, tuning in
            // Behavior, Execution and Permissions all edit `agentTuning`, so
            // the runtime publish lives here rather than in one pane. It runs
            // only on a change: applying rebuilds the model session, which
            // must not happen merely because Settings was opened. Stepper
            // edits arrive in bursts; the debounce publishes the settled value,
            // and the unstructured task still completes if the window closes.
            agentTuningPublish?.cancel()
            agentTuningPublish = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await chatStore.applyAgentTuning(tuning)
            }
        }
    }

    @ViewBuilder
    private func pane(for section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralSettingsView()
        case .shortcuts: ShortcutSettingsView()
        case .providers: ProviderSettingsView()
        case .reasoning: ReasoningSettingsView()
        case .routing: DynamicRoutingSettingsView()
        case .behavior: AgentBehaviorSettingsView()
        case .execution: AgentExecutionSettingsView()
        case .cowork: CoworkSettingsView()
        case .editorialDesk: EditorialDeskSettingsView()
        case .permissions: PermissionsSettingsView()
        }
    }
}

// MARK: - Icon tiles

extension SettingsGroup {
    /// Tile color shared by every pane of the group, so the sidebar reads as
    /// five colored bands. Kept in the view layer: the model stays free of
    /// SwiftUI.
    var tileColor: Color {
        switch self {
        case .turboCode: .gray
        case .intelligence: .blue
        case .agents: .purple
        case .workspaces: .green
        case .trust: .orange
        }
    }
}

/// A white symbol on a rounded tile in its group's color, as in System
/// Settings. The tile is decorative; the row's title carries the meaning.
struct SettingsIconTile: View {
    let section: SettingsSection
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: section.systemImage)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(section.group.tileColor.gradient, in: .rect(cornerRadius: size * 0.225))
            .accessibilityHidden(true)
    }
}

// MARK: - Pane header

/// The first section of every pane's `Form`: symbol, title, and the one
/// sentence that says what the pane decides.
struct SettingsPaneHeader: View {
    let section: SettingsSection

    var body: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIconTile(section: section, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title)
                        .font(.title3.bold())
                    Text(section.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

// MARK: - Cross-pane navigation

/// Selects another Settings pane. Injected by `SettingsRootView`; outside it
/// the default does nothing.
struct OpenSettingsSectionAction {
    private let handler: @MainActor (SettingsSection) -> Void

    init(_ handler: @escaping @MainActor (SettingsSection) -> Void) {
        self.handler = handler
    }

    @MainActor
    func callAsFunction(_ section: SettingsSection) {
        handler(section)
    }
}

extension EnvironmentValues {
    @Entry var openSettingsSection = OpenSettingsSectionAction { _ in }
}
