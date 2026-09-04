import SwiftUI
import AppKit

// MARK: - SettingsTabView — native macOS settings with a sidebar-style TabView

struct SettingsTabView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        TabView(selection: $selectedSection) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
                .tag(SettingsSection.general)

            EditorialDeskSettingsView()
                .tabItem { Label("Editorial Desk", systemImage: "newspaper") }
                .tag(SettingsSection.editorialDesk)

            ProviderSettingsView()
                .tabItem { Label("Providers", systemImage: "network") }
                .tag(SettingsSection.providers)

            ReasoningSettingsView()
                .tabItem { Label("Reasoning", systemImage: "brain") }
                .tag(SettingsSection.reasoning)

            AgentSettingsView()
                .tabItem { Label("Agents", systemImage: "wand.and.stars") }
                .tag(SettingsSection.agents)

            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsSection.shortcuts)

        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 600, minHeight: 400)
        .environment(settings)
    }
}

// MARK: - Editorial Desk Settings

struct EditorialDeskSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            Section {
                Text("Define the sections and article types available in the Editorial Desk metadata bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Sections") {
                if settings.editorialDeskCatalog.sections.isEmpty {
                    Text("No sections configured.")
                        .foregroundStyle(.secondary)
                }

                ForEach(settings.editorialDeskCatalog.sections) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .frame(width: 22)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            TextField(
                                "Section name",
                                text: sectionNameBinding(section.id)
                            )
                            .textFieldStyle(.roundedBorder)

                            EditorialDeskSymbolPicker(
                                selection: sectionSymbolBinding(section.id),
                                context: .section
                            )
                        }

                        Button(role: .destructive) {
                            removeSection(section.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove section")
                    }
                }

                Button {
                    var catalog = settings.editorialDeskCatalog
                    catalog.sections.append(
                        EditorialDeskSection(
                            name: "New section",
                            systemImage: "square.grid.2x2"
                        )
                    )
                    settings.editorialDeskCatalog = catalog
                } label: {
                    Label("Add Section", systemImage: "plus")
                }
            }

            Section("Article Types") {
                if settings.editorialDeskCatalog.types.isEmpty {
                    Text("No article types configured.")
                        .foregroundStyle(.secondary)
                }

                ForEach(settings.editorialDeskCatalog.types) { type in
                    HStack(spacing: 10) {
                        Image(systemName: type.systemImage)
                            .frame(width: 22)
                            .foregroundStyle(Color(editorialHex: type.colorHex))

                        VStack(alignment: .leading, spacing: 6) {
                            TextField(
                                "Type name",
                                text: typeNameBinding(type.id)
                            )
                            .textFieldStyle(.roundedBorder)

                            EditorialDeskSymbolPicker(
                                selection: typeSymbolBinding(type.id),
                                context: .articleType
                            )

                            ColorPicker(
                                "Color",
                                selection: typeColorBinding(type.id),
                                supportsOpacity: false
                            )
                        }

                        Button(role: .destructive) {
                            removeType(type.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove article type")
                    }
                }

                Button {
                    var catalog = settings.editorialDeskCatalog
                    catalog.types.append(
                        EditorialDeskType(
                            name: "New type",
                            systemImage: "doc.text",
                            colorHex: "#007AFF"
                        )
                    )
                    settings.editorialDeskCatalog = catalog
                } label: {
                    Label("Add Article Type", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func sectionNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: {
                settings.editorialDeskCatalog.sections.first(where: { $0.id == id })?.name ?? ""
            },
            set: { updateSection(id, name: $0) }
        )
    }

    private func sectionSymbolBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: {
                settings.editorialDeskCatalog.sections.first(where: { $0.id == id })?.systemImage ?? ""
            },
            set: { updateSection(id, systemImage: $0) }
        )
    }

    private func typeNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: {
                settings.editorialDeskCatalog.types.first(where: { $0.id == id })?.name ?? ""
            },
            set: { updateType(id, name: $0) }
        )
    }

    private func typeSymbolBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: {
                settings.editorialDeskCatalog.types.first(where: { $0.id == id })?.systemImage ?? ""
            },
            set: { updateType(id, systemImage: $0) }
        )
    }

    private func typeColorBinding(_ id: UUID) -> Binding<Color> {
        Binding(
            get: {
                Color(
                    editorialHex: settings.editorialDeskCatalog.types
                        .first(where: { $0.id == id })?.colorHex ?? "#007AFF"
                )
            },
            set: { updateType(id, colorHex: $0.editorialHexValue) }
        )
    }

    private func updateSection(
        _ id: UUID,
        name: String? = nil,
        systemImage: String? = nil
    ) {
        var catalog = settings.editorialDeskCatalog
        guard let index = catalog.sections.firstIndex(where: { $0.id == id }) else { return }
        if let name { catalog.sections[index].name = name }
        if let systemImage { catalog.sections[index].systemImage = systemImage }
        settings.editorialDeskCatalog = catalog
    }

    private func updateType(
        _ id: UUID,
        name: String? = nil,
        systemImage: String? = nil,
        colorHex: String? = nil
    ) {
        var catalog = settings.editorialDeskCatalog
        guard let index = catalog.types.firstIndex(where: { $0.id == id }) else { return }
        if let name { catalog.types[index].name = name }
        if let systemImage { catalog.types[index].systemImage = systemImage }
        if let colorHex { catalog.types[index].colorHex = colorHex }
        settings.editorialDeskCatalog = catalog
    }

    private func removeSection(_ id: UUID) {
        var catalog = settings.editorialDeskCatalog
        catalog.sections.removeAll { $0.id == id }
        settings.editorialDeskCatalog = catalog
    }

    private func removeType(_ id: UUID) {
        var catalog = settings.editorialDeskCatalog
        catalog.types.removeAll { $0.id == id }
        settings.editorialDeskCatalog = catalog
    }
}

private struct EditorialDeskSymbolPicker: View {
    @Binding var selection: String
    let context: EditorialDeskSymbolContext

    private var options: [EditorialDeskSymbolOption] {
        EditorialDeskSymbolCatalog.options(for: context)
    }

    private var groupedOptions: [(category: String, options: [EditorialDeskSymbolOption])] {
        Dictionary(grouping: options, by: \.category)
            .keys
            .sorted()
            .map { category in
                (
                    category: category,
                    options: options.filter { $0.category == category }
                )
            }
    }

    private var displaySymbol: String {
        guard !selection.isEmpty,
              NSImage(systemSymbolName: selection, accessibilityDescription: nil) != nil else {
            return "questionmark.square.dashed"
        }
        return selection
    }

    private var displayName: String {
        selection.isEmpty ? "Choose SF Symbol" : selection
    }

    var body: some View {
        Menu {
            ForEach(groupedOptions, id: \.category) { group in
                Section(group.category) {
                    ForEach(group.options) { option in
                        Button {
                            selection = option.name
                        } label: {
                            Label(option.name, systemImage: option.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: displaySymbol)
                    .frame(width: 18)
                Text(displayName)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .help("Choose a system SF Symbol")
    }
}

private extension Color {
    init(editorialHex hex: String) {
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt64(normalized, radix: 16) else {
            self = .accentColor
            return
        }

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }

    var editorialHexValue: String {
        let color = NSColor(self).usingColorSpace(.deviceRGB) ?? .controlAccentColor
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "#%02lX%02lX%02lX",
            lround(Double(red * 255)),
            lround(Double(green * 255)),
            lround(Double(blue * 255))
        )
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let s = Bindable(settings)
        return Form {
            Section("Appearance") {
                Picker("Theme", selection: s.theme) {
                    Text("System").tag(ThemePreference.system)
                    Text("Light").tag(ThemePreference.light)
                    Text("Dark").tag(ThemePreference.dark)
                }

                HStack {
                    Text("Chat text size")
                    Slider(value: s.fontSize, in: 13...20, step: 1)
                    Text("\(Int(settings.fontSize))")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 24)
                }
            }

            Section("Chat") {
                HStack {
                    Text("Content width")
                    Slider(value: s.maxChatWidth, in: 640...1600, step: 20)
                    Text("\(Int(settings.maxChatWidth))")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 40)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Provider Settings

struct ReasoningSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @State private var selectedModelID = ""
    @State private var reasoningDraft: RemoteReasoningConfiguration = .serverManaged
    @State private var reasoningSaveError: String?

    var body: some View {
        Form {
            Section("Remote Reasoning") {
                if configurableModels.isEmpty {
                    Text("No compatible remote models are configured.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: $selectedModelID) {
                        ForEach(configurableModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }

                    Picker("Control", selection: $reasoningDraft.mode) {
                        Text("Managed by server")
                            .tag(RemoteReasoningControlMode.serverManaged)
                        Text("Per-request token budget")
                            .tag(RemoteReasoningControlMode.requestTokenBudget)
                    }

                    if reasoningDraft.mode == .requestTokenBudget {
                        LabeledContent("Low") {
                            tokenBudgetField($reasoningDraft.lowTokenBudget)
                        }
                        LabeledContent("Medium") {
                            tokenBudgetField($reasoningDraft.mediumTokenBudget)
                        }
                        LabeledContent("High") {
                            tokenBudgetField($reasoningDraft.highTokenBudget)
                        }
                        Toggle("Unlimited maximum", isOn: unlimitedMaximumBinding)
                        if reasoningDraft.maximumTokenBudget != nil {
                            LabeledContent("Maximum") {
                                tokenBudgetField(finiteMaximumBinding)
                            }
                        }
                    }

                    Text(reasoningExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let reasoningSaveError {
                        Label(reasoningSaveError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Spacer()
                        Button("Apply") {
                            applyReasoningConfiguration()
                        }
                        .disabled(!reasoningDraftHasChanges)
                    }
                }
            }

        }
        .formStyle(.grouped)
        .padding()
        .task {
            selectInitialReasoningModelIfNeeded()
        }
        .onChange(of: selectedModelID) {
            loadReasoningDraft()
        }
    }

    private var configurableModels: [RemoteModelConfig] {
        settings.remoteModels.filter {
            $0.provider == .openAICompatible && $0.role == .local
        }
    }

    private var selectedReasoningModel: RemoteModelConfig? {
        configurableModels.first(where: { $0.id == selectedModelID })
    }

    private var reasoningDraftHasChanges: Bool {
        guard let selectedReasoningModel else { return false }
        return reasoningDraft != selectedReasoningModel.reasoningConfiguration
    }

    private var reasoningExplanation: String {
        switch reasoningDraft.mode {
        case .serverManaged:
            "TurboCode adds no reasoning fields. The endpoint uses its launch and template configuration."
        case .requestTokenBudget:
            "TurboCode sends a thinking switch and the selected token budget with each request."
        }
    }

    private var unlimitedMaximumBinding: Binding<Bool> {
        Binding(
            get: { reasoningDraft.maximumTokenBudget == nil },
            set: { isUnlimited in
                reasoningDraft.maximumTokenBudget = isUnlimited
                    ? nil
                    : max(reasoningDraft.highTokenBudget, 16_384)
            }
        )
    }

    private var finiteMaximumBinding: Binding<Int> {
        Binding(
            get: { reasoningDraft.maximumTokenBudget ?? 16_384 },
            set: { reasoningDraft.maximumTokenBudget = $0 }
        )
    }

    private func tokenBudgetField(_ value: Binding<Int>) -> some View {
        TextField("Tokens", value: value, format: .number)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 120)
    }

    private func selectInitialReasoningModelIfNeeded() {
        guard !configurableModels.isEmpty else { return }
        if !configurableModels.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = configurableModels[0].id
        }
        loadReasoningDraft()
    }

    private func loadReasoningDraft() {
        guard let selectedReasoningModel else { return }
        reasoningDraft = selectedReasoningModel.reasoningConfiguration
        reasoningSaveError = nil
    }

    private func applyReasoningConfiguration() {
        do {
            try settings.updateReasoningConfiguration(
                reasoningDraft,
                for: selectedModelID
            )
            reasoningSaveError = nil
            Task { await chatStore.reloadRemoteModels() }
        } catch {
            reasoningSaveError = error.localizedDescription
        }
    }
}

struct ProviderSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        let s = Bindable(settings)
        return Form {
            Section("DeepSeek") {
                SecureField("API Key", text: s.deepseekAPIKey)
                    .textFieldStyle(.roundedBorder)

                Label(
                    settings.deepSeekCredentialConfigured || !settings.deepseekAPIKey.isEmpty
                        ? "Configured"
                        : "Not configured",
                    systemImage: settings.deepSeekCredentialConfigured || !settings.deepseekAPIKey.isEmpty
                        ? "checkmark.circle"
                        : "key.slash"
                )
                .foregroundStyle(
                    settings.deepSeekCredentialConfigured || !settings.deepseekAPIKey.isEmpty
                        ? Color.green
                        : Color.secondary
                )

                if let error = settings.credentialError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            settings.loadDeepSeekCredentialForSettings()
        }
        .task(id: settings.deepseekAPIKey) {
            // Key entry mutates on every keystroke. Debouncing keeps provider
            // catalog refresh explicit and prevents rebuilding a model session
            // for intermediate credential values SwiftUI immediately replaces.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await chatStore.reloadRemoteModels()
        }
    }
}

// MARK: - Agent Settings

struct AgentSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        let s = Bindable(settings)
        return Form {
            Section("Responses") {
                Picker("Detail", selection: s.agentTuning.agent.responseStyle) {
                    Text("Concise").tag(AgentResponseStyle.concise)
                    Text("Balanced").tag(AgentResponseStyle.balanced)
                    Text("Detailed").tag(AgentResponseStyle.detailed)
                }
                Toggle("Verify source changes", isOn: s.agentTuning.agent.verifiesChanges)
            }

            Section("Default Delegated Worker") {
                Picker(
                    "Worker",
                    selection: s.agentTuning.orchestrator.delegateModelID
                ) {
                    if settings.selectedOrchestratorModel == nil {
                        Text("Unavailable (\(settings.agentTuning.orchestrator.delegateModelID))")
                            .tag(settings.agentTuning.orchestrator.delegateModelID)
                    }
                    ForEach(settings.orchestratorModelOptions) { model in
                        Text(model.name)
                            .tag(model.id)
                            .disabled(!settings.isConfigured(model))
                    }
                }

                Text("Fallback for older profiles and experimental on-device delegation. New coordinator profiles store their worker in Custom Profiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let selected = settings.selectedOrchestratorModel,
                   !settings.isConfigured(selected) {
                    Label(
                        "\(selected.name) requires its credential before it can be used.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                } else if settings.selectedOrchestratorModel == nil {
                    Label(
                        "The selected model ID is not present in models.json.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Execution") {
                Stepper(
                    value: s.agentTuning.execution.defaultCommandTimeoutSeconds,
                    in: 5...settings.agentTuning.execution.maximumCommandTimeoutSeconds,
                    step: 5
                ) {
                    LabeledContent("Command timeout") {
                        Text("\(settings.agentTuning.execution.defaultCommandTimeoutSeconds)s")
                            .monospacedDigit()
                    }
                }

                Stepper(
                    value: s.agentTuning.execution.maximumToolOutputCharacters,
                    in: 1_000...30_000,
                    step: 1_000
                ) {
                    LabeledContent("Maximum tool output") {
                        Text("\(settings.agentTuning.execution.maximumToolOutputCharacters)")
                            .monospacedDigit()
                    }
                }

                Toggle("Allow command network access", isOn: s.agentTuning.execution.allowNetworkAccess)
            }

            Section("Skills") {
                Toggle("Discover user skills", isOn: s.agentTuning.skills.discoversUserSkills)
            }

            Section("Experimental") {
                Toggle("Safari MCP", isOn: s.agentTuning.experimental.safariMCPEnabled)

                Text("Allows an explicitly activated skill to control Safari through safaridriver MCP. Disabled by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Allow third-party plugins",
                    isOn: s.agentTuning.experimental.thirdPartyPluginsEnabled
                )

                Text("Allows installed Node.js plugins to start and expose tools to selected profiles. Plugins run as normal local processes with filesystem, network, and subprocess access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    settings.reloadAgentTuning()
                } label: {
                    Label("Reload Configuration", systemImage: "arrow.clockwise")
                }

                if let error = settings.agentTuningError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task(id: settings.agentTuning) {
            // Slider and stepper edits can arrive in bursts. The cancellable
            // view task publishes only the settled configuration to runtime.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await chatStore.applyAgentTuning(settings.agentTuning)
        }
    }
}

// MARK: - Shortcut Settings

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section("Navigation") {
                ShortcutRow(label: "New Chat", shortcut: "⌘N")
                ShortcutRow(label: "Toggle Sidebar", shortcut: "⌘S")
            }

            Section("Actions") {
                ShortcutRow(label: "Choose Workspace", shortcut: "⇧⌘O")
            }

            Section("Views") {
                ShortcutRow(label: "Settings", shortcut: "⌘,")
                ShortcutRow(label: "Chat", shortcut: "⌘1")
                ShortcutRow(label: "Custom Profiles", shortcut: "⌘2")
                ShortcutRow(label: "Tools", shortcut: "⌘3")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ShortcutRow: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(shortcut)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
