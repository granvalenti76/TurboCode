import SwiftUI
import AppKit

// MARK: - Editorial Desk Settings

struct EditorialDeskSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        Form {
            SettingsPaneHeader(section: .editorialDesk)

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
            SettingsPaneHeader(section: .general)
            AgentIdentitySection()
            Section("Appearance") {
                Picker("Theme", selection: s.theme) {
                    Text("System").tag(ThemePreference.system)
                    Text("Light").tag(ThemePreference.light)
                    Text("Dark").tag(ThemePreference.dark)
                }

                Picker("Sidebar", selection: s.sidebarBackdrop) {
                    Text("Translucent").tag(SidebarBackdropPreference.translucent)
                    Text("Solid").tag(SidebarBackdropPreference.solid)
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

            Section("Workbench") {
                Toggle(isOn: s.projectTerminalEnabled) {
                    Text("Show project terminal")
                    Text("Adds a button that opens a shell in the current workspace.")
                }
            }

            Section("Notifications") {
                Toggle(isOn: s.replyNotificationsEnabled) {
                    Text("Notify when a reply is ready")
                    Text("Only while TurboCode is in the background.")
                }
                Toggle(isOn: s.replyNotificationExcerptEnabled) {
                    Text("Show a preview of the reply")
                    Text("Notifications can appear on the lock screen.")
                }
                .disabled(!settings.replyNotificationsEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Provider Settings

struct ReasoningSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @State private var selectedModelID = ""
    @State private var reasoningDraft: RemoteReasoningConfiguration = .serverManaged
    @State private var reasoningSaveError: String?
    @State private var isDetectingEffortLevels = false

    var body: some View {
        Form {
            SettingsPaneHeader(section: .reasoning)
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
                        Text("Server effort levels (/props)")
                            .tag(RemoteReasoningControlMode.requestEffortLevel)
                    }

                    if reasoningDraft.mode == .requestEffortLevel {
                        LabeledContent("Levels") {
                            if isDetectingEffortLevels {
                                ProgressView().controlSize(.small)
                            } else if let levels = reasoningDraft.serverEffortLevels {
                                Text(levels.joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not detected").foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Detect Again") { detectEffortLevels() }
                                .disabled(isDetectingEffortLevels)
                        }
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
        .task {
            selectInitialReasoningModelIfNeeded()
        }
        .onChange(of: selectedModelID) {
            loadReasoningDraft()
        }
        .onChange(of: reasoningDraft.mode) { _, mode in
            // Detect on every explicit selection so a model swapped on the
            // server is picked up without editing `models.json`.
            if mode == .requestEffortLevel { detectEffortLevels() }
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
        case .requestEffortLevel:
            "TurboCode reads the levels the chat template accepts from the server's /props and sends the selected one as reasoning_effort with each request."
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

    /// Read-only probe of the selected endpoint. Levels are stored only in the
    /// draft; nothing is persisted until the user presses Apply.
    private func detectEffortLevels() {
        guard let url = selectedReasoningModel?.url else { return }
        let modelID = selectedModelID
        isDetectingEffortLevels = true
        reasoningSaveError = nil
        Task {
            let levels = await LlamaServerRuntimeProbe.reasoningEffortLevels(from: url)
            isDetectingEffortLevels = false
            guard selectedModelID == modelID,
                  reasoningDraft.mode == .requestEffortLevel else { return }
            reasoningDraft.serverEffortLevels = levels
            if levels == nil {
                reasoningSaveError = "The server does not report reasoning effort levels in /props."
            }
        }
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
            SettingsPaneHeader(section: .providers)
            LocalServerSettingsSection()
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

// MARK: - Agent Behavior Settings

/// How agents answer, verify their edits, and delegate. Network and
/// integration switches moved to `PermissionsSettingsView` so every option
/// that widens access lives in one pane.
struct AgentBehaviorSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    /// The threshold doubles as the switch: 0 is off, and turning it back on
    /// restores the default rather than an arbitrary remembered value.
    private var autoCompactEnabled: Binding<Bool> {
        Binding(
            get: { settings.agentTuning.agent.autoCompactThresholdPercent > 0 },
            set: { enabled in
                settings.agentTuning.agent.autoCompactThresholdPercent = enabled
                    ? AgentPolicy.defaultAutoCompactThresholdPercent
                    : 0
            }
        )
    }

    var body: some View {
        let s = Bindable(settings)
        return Form {
            SettingsPaneHeader(section: .behavior)

            Section("Responses") {
                Picker("Detail", selection: s.agentTuning.agent.responseStyle) {
                    Text("Concise").tag(AgentResponseStyle.concise)
                    Text("Balanced").tag(AgentResponseStyle.balanced)
                    Text("Detailed").tag(AgentResponseStyle.detailed)
                }
                Toggle("Verify source changes", isOn: s.agentTuning.agent.verifiesChanges)
            }

            Section("Context") {
                Toggle("Compact automatically", isOn: autoCompactEnabled)
                if settings.agentTuning.agent.autoCompactThresholdPercent > 0 {
                    // Discrete steps, not a slider: every settings change
                    // rebuilds the model session, so dragging would rebuild
                    // it once per intermediate value.
                    Picker(
                        "When context reaches",
                        selection: s.agentTuning.agent.autoCompactThresholdPercent
                    ) {
                        ForEach(Array(stride(from: 50, through: 95, by: 5)), id: \.self) { percent in
                            Text("\(percent)%").tag(percent)
                        }
                    }
                }
                Text("Local llama-server only. Before the next message, TurboCode replaces the conversation with the same summary as /compact.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Toggle(
                    "Run delegated tasks in background",
                    isOn: s.agentTuning.orchestrator.runsDelegatedTasksInBackground
                )
                .help(
                    "Return control after the worker starts and report its result when it finishes."
                )

                Text("Returns control immediately. TurboCode reports the result in the originating conversation when the worker finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Section("Skills") {
                Toggle("Discover user skills", isOn: s.agentTuning.skills.discoversUserSkills)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Agent Execution Settings

struct AgentExecutionSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let s = Bindable(settings)
        return Form {
            SettingsPaneHeader(section: .execution)

            Section("Limits") {
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
    }
}

// MARK: - Dynamic Routing Settings

struct DynamicRoutingSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        Form {
            SettingsPaneHeader(section: .routing)

            Section {
                Toggle("Enable Dynamic Routing", isOn: Binding(
                    get: { chatStore.dynamicRoutingFeatureEnabled },
                    set: { enabled in
                        Task {
                            await chatStore.setDynamicRoutingFeatureEnabled(enabled)
                        }
                    }
                ))
                .disabled(!settings.anchorSignalAssets.isReady)

                Text("Uses an optional on-device AI model to choose which tool calls are available for each response. TurboCode reuses the current model session when the tool set stays the same, preserving the KV cache whenever possible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Model") {
                    HStack(spacing: 8) {
                        if settings.anchorSignalAssets.state.isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(settings.anchorSignalAssets.state.title)
                            .foregroundStyle(dynamicRoutingStatusColor)
                    }
                }

                Text("Downloads 277 MB and uses approximately 487 MB after installation. CoreAI stores the device specialization in its managed cache.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if case .failed(let message) = settings.anchorSignalAssets.state {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !settings.anchorSignalAssets.isReady {
                    Button(dynamicRoutingActionTitle) {
                        Task {
                            if await settings.anchorSignalAssets.installAndPrepare() {
                                await chatStore.setDynamicRoutingFeatureEnabled(true)
                            }
                        }
                    }
                    .disabled(settings.anchorSignalAssets.state.isWorking)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            settings.anchorSignalAssets.refreshStatus()
            if !settings.anchorSignalAssets.isReady,
               chatStore.dynamicRoutingFeatureEnabled {
                await chatStore.setDynamicRoutingFeatureEnabled(false)
            }
        }
    }

    private var dynamicRoutingActionTitle: String {
        switch settings.anchorSignalAssets.state {
        case .needsPreparation:
            "Prepare Model"
        case .failed:
            "Try Again"
        default:
            "Download and Enable"
        }
    }

    private var dynamicRoutingStatusColor: Color {
        switch settings.anchorSignalAssets.state {
        case .ready:
            .green
        case .failed:
            .red
        default:
            .secondary
        }
    }
}

// MARK: - Shortcut Settings

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            SettingsPaneHeader(section: .shortcuts)
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
            }
        }
        .formStyle(.grouped)
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
