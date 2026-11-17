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
                            Label(section.title, systemImage: section.systemImage)
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
            .navigationSplitViewColumnWidth(220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane(for: current)
                .navigationTitle(current.title)
                // Panes link to each other (Permissions → Studio) through
                // this action instead of owning the selection.
                .environment(\.openSettingsSection, OpenSettingsSectionAction { selection = $0 })
        }
        .frame(minWidth: 760, minHeight: 560)
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

// MARK: - Pane header

/// The first section of every pane's `Form`: symbol, title, and the one
/// sentence that says what the pane decides.
struct SettingsPaneHeader: View {
    let section: SettingsSection

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: section.systemImage)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.tint, in: .rect(cornerRadius: 9))
                    .accessibilityHidden(true)

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
