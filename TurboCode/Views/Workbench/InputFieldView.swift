import SwiftUI

// MARK: - InputFieldView — Composer input card

struct InputFieldView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(ComposerCommandRouter.self) private var commandRouter
    @Environment(ComposerViewModel.self) private var composer
    @Environment(ChatPresentationViewModel.self) private var presentation
    @Environment(\.chatFontSize) private var chatFontSize
    @FocusState private var isFocused: Bool
    @State private var selectedSlashCommandIndex = 0
    @State private var isLlamaContextHovering = false

    let compact: Bool

    // Persisted preferences
    @AppStorage("reasoningEffort") private var reasoningEffort: ReasoningEffort = .medium

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        VStack(spacing: 0) {
            composerCard
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .background(Color(.windowBackgroundColor))
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, compact ? 16 : 12)
    }

    // MARK: - Composer Card

    private var composerCard: some View {
        VStack(spacing: 0) {
            // ── Top section: text field + controls ──
            VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                textField

                HStack(spacing: 10) {
                    Spacer()

                    backendMenu
                    sendButton
                }
            }
            .padding(16)

            Divider()

            // ── Bottom info bar ──
            bottomInfoBar
        }
    }

    // MARK: - Text Field

    private var textField: some View {
        // Keep the invitation workspace-oriented; the active profile and tools
        // provide specialization without narrowing what users think they can ask.
        return VStack(alignment: .leading, spacing: 8) {
            TextField(
                "What would you like to do in this project?",
                text: Binding(
                    get: { composer.messageText },
                    set: { composer.messageText = $0 }
                ),
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .font(AppTypography.chatBody(size: chatFontSize))
                .lineLimit(1...10)
                .focused($isFocused)
                .disabled(chatStore.busy)
                .padding(.bottom, compact ? 12 : 18)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        guard !chatStore.busy else { return }
                        isFocused = true
                    }
                )
                .onChange(of: composer.messageText) { oldValue, newValue in
                    // A changed query describes a new result set; keeping the
                    // previous row selected could execute the wrong command.
                    selectedSlashCommandIndex = 0
                    // Inspector recovery actions prepare a reviewable draft
                    // rather than executing work immediately. Focus only when
                    // text is inserted externally, not while the user types.
                    if oldValue.isEmpty && !newValue.isEmpty && !isFocused {
                        isFocused = true
                    }
                }
                .onChange(of: chatStore.busy) { _, isBusy in
                    guard !isBusy else { return }
                    // Responses disable the field while they stream. Restore
                    // the insertion point as soon as the response reaches a
                    // terminal state so the next prompt needs no extra click.
                    isFocused = true
                }
                .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in
                    handleComposerKeyPress(press)
                }

            if isFocused && !chatStore.busy && !slashSuggestions.isEmpty {
                slashCommandMenu
            }
        }
    }

    private var slashCommandMenu: some View {
        VStack(spacing: 0) {
            ForEach(Array(slashSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                if index > 0 {
                    Divider()
                        .padding(.leading, 34)
                }

                Button {
                    composer.messageText = suggestion.insertion
                    isFocused = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Text(suggestion.command)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppTypography.chatForeground)

                        Text(suggestion.description)
                            .font(AppTypography.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .background(
                        index == selectedSlashCommandIndex
                            ? Color.accentColor.opacity(0.14)
                            : .clear
                    )
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    index == selectedSlashCommandIndex ? .isSelected : []
                )
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    private func handleComposerKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !slashSuggestions.isEmpty, !chatStore.busy else { return .ignored }

        switch press.key {
        case .upArrow:
            moveSlashSelection(by: -1)
            return .handled
        case .downArrow:
            moveSlashSelection(by: 1)
            return .handled
        case .return:
            executeSelectedSlashCommand()
            return .handled
        default:
            return .ignored
        }
    }

    private func moveSlashSelection(by offset: Int) {
        guard !slashSuggestions.isEmpty else { return }
        let count = slashSuggestions.count
        selectedSlashCommandIndex = (selectedSlashCommandIndex + offset + count) % count
    }

    /// Executes a selected complete slash command. `/skill` and `/task` remain
    /// insertion steps because both require a parameter before execution.
    private func executeSelectedSlashCommand() {
        let suggestion = slashSuggestions[
            min(max(selectedSlashCommandIndex, 0), slashSuggestions.count - 1)
        ]
        guard suggestion.command != "/skill", suggestion.command != "/task" else {
            composer.messageText = suggestion.insertion
            isFocused = true
            return
        }

        let command = suggestion.command
        composer.reset()
        isFocused = false
        Task {
            if await commandRouter.execute(command) == false {
                await chatStore.sendMessage(command)
            }
        }
    }

    private var slashSuggestions: [SlashCommandSuggestion] {
        let input = composer.messageText
        guard input.hasPrefix("/"), !input.contains("\n") else { return [] }

        if input.hasPrefix("/skill ") {
            let query = String(input.dropFirst("/skill ".count)).lowercased()
            return chatStore.availableSkills
                .filter { query.isEmpty || $0.name.contains(query) }
                .prefix(6)
                .map {
                    SlashCommandSuggestion(
                        command: "/skill \($0.name)",
                        insertion: "/skill \($0.name) ",
                        description: $0.description,
                        icon: "bolt"
                    )
                }
        }

        guard !input.contains(" ") else { return [] }
        let query = input.lowercased()
        let commands = [
            SlashCommandSuggestion(
                command: "/task",
                insertion: "/task ",
                description: "Run an independent worker task",
                icon: "person.2"
            ),
            SlashCommandSuggestion(
                command: "/documentation",
                insertion: "/documentation",
                description: "Open TurboCode documentation",
                icon: "book.closed"
            ),
            SlashCommandSuggestion(
                command: "/skills",
                insertion: "/skills",
                description: "List available skills",
                icon: "square.stack.3d.up"
            ),
            SlashCommandSuggestion(
                command: "/skill",
                insertion: "/skill ",
                description: "Choose a skill for this request",
                icon: "bolt"
            ),
            SlashCommandSuggestion(
                command: "/compact",
                insertion: "/compact",
                description: "Compact conversation context for local models",
                icon: "arrow.triangle.2.circle.clockwise"
            ),
            SlashCommandSuggestion(
                command: "/reload",
                insertion: "/reload",
                description: "Reload profiles without rebuilding this session",
                icon: "arrow.clockwise"
            )
        ] + chatStore.availableSkills.map {
            SlashCommandSuggestion(
                command: "/\($0.name)",
                insertion: "/\($0.name) ",
                description: $0.description,
                icon: "bolt"
            )
        }

        return Array(commands.filter {
            query == "/" || $0.command.lowercased().hasPrefix(query)
        }.prefix(6))
    }

    // MARK: - Backend Menu

    private var backendMenu: some View {
        let isOrchestrating = chatStore.orchestratorMode == .orchestrator

        return Group {
            if isOrchestrating {
                // In orchestrator mode: Apple always responds, Llama is the delegate
                Label("Apple · Orchestrator", systemImage: "square.2.layers.3d")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Menu {
                    Section("Default Profiles") {
                        Button {
                            Task { await chatStore.selectBuiltInProfile(.onDevice) }
                        } label: {
                            if chatStore.activeDynamicProfileID == nil,
                               chatStore.activeBackend == .foundationApple {
                                Label("On-device", systemImage: "checkmark")
                            } else {
                                Text("On-device")
                            }
                        }

                        codexProfileMenu

                        ForEach(chatStore.enabledRemoteModels) { model in
                            Button {
                                Task { await chatStore.switchRemoteModel(to: model.id) }
                            } label: {
                                if chatStore.activeDynamicProfileID == nil,
                                   chatStore.activeRemoteModelID == model.id,
                                   chatStore.activeBackend != .foundationApple,
                                   chatStore.activeBackend != .codex {
                                    Label(model.name, systemImage: "checkmark")
                                } else {
                                    Text(model.name)
                                }
                            }
                    }
                    }

                    if !chatStore.dynamicProfiles.isEmpty {
                        Section("Custom Profiles") {
                            ForEach(chatStore.dynamicProfiles) { profile in
                                Button {
                                    Task { await chatStore.selectDynamicProfile(profile.id) }
                                } label: {
                                    if chatStore.activeDynamicProfileID == profile.id {
                                        Label(profile.name, systemImage: "checkmark")
                                    } else {
                                        Text(profile.name)
                                    }
                                }
                            }
                        }
                    }

                    if chatStore.activeModelSupportsReasoning,
                       chatStore.activeBackend != .codex {
                        Divider()
                        Section("Reasoning") {
                            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                                Button {
                                    reasoningEffort = effort
                                    Task { await chatStore.setReasoningEffort(effort) }
                                } label: {
                                    if reasoningEffort == effort {
                                        Label(
                                            effort.rawValue,
                                            systemImage: "checkmark"
                                        )
                                    } else {
                                        Text(effort.rawValue)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    if chatStore.activeModelSupportsReasoning {
                        Text(
                            "\(chatStore.composerModel) · \(activeReasoningLabel)"
                        )
                    } else {
                        Text(chatStore.composerModel)
                    }
                }
                .menuStyle(.borderlessButton)
                .font(AppTypography.controlEmphasized)
                .fixedSize()
            }
        }
        .disabled(chatStore.busy)
    }

    /// Keeps the primary profile menu compact. Model and reasoning choices
    /// appear only after the user opens Codex, following macOS progressive
    /// disclosure instead of flattening every server-provided model.
    private var codexProfileMenu: some View {
        Menu {
            Section("Model") {
                if chatStore.codexModels.isEmpty {
                    Button {
                        chatStore.requestCodexProfileSelection()
                    } label: {
                        if chatStore.activeBackend == .codex {
                            Label(
                                chatStore.codexDisplayName,
                                systemImage: "checkmark"
                            )
                        } else {
                            Text("Luna")
                        }
                    }
                    .help("Connect to Codex and load available models")
                } else {
                    ForEach(chatStore.codexModels) { model in
                        Button {
                            chatStore.requestCodexProfileSelection(
                                modelID: model.id
                            )
                        } label: {
                            if chatStore.activeBackend == .codex,
                               chatStore.codexModel?.id == model.id {
                                Label(
                                    model.displayName,
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(model.displayName)
                            }
                        }
                        .help(model.description)
                    }
                }
            }

            if chatStore.activeBackend == .codex {
                Divider()
                Section("Reasoning") {
                    ForEach(
                        chatStore.codexReasoningOptions,
                        id: \.reasoningEffort
                    ) { option in
                        Button {
                            chatStore.setCodexReasoningEffort(
                                option.reasoningEffort
                            )
                        } label: {
                            if chatStore.codexReasoningEffort
                                == option.reasoningEffort {
                                Label(
                                    option.reasoningEffort.displayName,
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(option.reasoningEffort.displayName)
                            }
                        }
                        .help(option.description)
                    }
                }
            }
        } label: {
            if chatStore.activeBackend == .codex {
                Label("Codex", systemImage: "checkmark")
            } else {
                Text("Codex")
            }
        }
    }

    private var activeReasoningLabel: String {
        if chatStore.activeBackend == .codex {
            return chatStore.codexReasoningEffort.displayName
        }
        return reasoningEffort.rawValue
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button {
            sendComposerInput()
        } label: {
            Image(systemName: chatStore.busy ? "stop.fill" : "arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .clipShape(Circle())
        .disabled(
            !chatStore.busy
                && (
                    composer.messageText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    || commandRouter.isIncompleteSkillCommand(composer.messageText)
                    || commandRouter.isIncompleteTaskCommand(composer.messageText)
                    || (
                        !chatStore.activeProfileCanSend
                            && !commandRouter.isLocalCommand(composer.messageText)
                    )
                )
        )
        .keyboardShortcut(.return, modifiers: [])
        .help(sendButtonHelp)
    }

    private func sendComposerInput() {
        if chatStore.busy {
            Task { await chatStore.interrupt() }
            return
        }
        let text = composer.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if commandRouter.isIncompleteSkillCommand(text) {
            composer.messageText = "/skill "
            isFocused = true
            return
        }
        if commandRouter.isIncompleteTaskCommand(text) {
            composer.messageText = "/task "
            isFocused = true
            return
        }
        // Clear the shared draft before starting inference so recovery drafts
        // and ordinary composer input follow the same lifecycle.
        composer.reset()
        Task {
            if await commandRouter.execute(text) == false {
                await chatStore.sendMessage(text)
            }
        }
    }

    private var sendButtonHelp: String {
        if chatStore.busy { return "Stop response" }
        if !chatStore.activeProfileCanSend
            && !commandRouter.isLocalCommand(composer.messageText) {
            return "Wait for Codex to connect or sign in first"
        }
        return "Send message"
    }

    // MARK: - Bottom Info Bar

    private var bottomInfoBar: some View {
        HStack(spacing: 16) {
            executionRouteMenu
            branchMenu

            Spacer()

            if chatStore.activeBackend == .llamaServer,
               let contextUsage = presentation.llamaContextUsage {
                llamaContextIndicator(contextUsage)
            }
        }
        .font(AppTypography.controlEmphasized)
        .foregroundStyle(.secondary)
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.vertical, compact ? 7 : 8)
    }

    /// Keeps Llama's runtime pressure visible without adding controls or
    /// changing the footer for the other provider profiles.
    private func llamaContextIndicator(_ usage: LlamaContextUsage) -> some View {
        return ZStack {
            Circle()
                .stroke(.secondary.opacity(0.18), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: usage.fraction)
                .stroke(
                    contextColor(for: usage.level),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isLlamaContextHovering = hovering
            }
        }
        .overlay(alignment: .bottom) {
            if isLlamaContextHovering {
                Text(usage.tooltipText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator.opacity(0.55), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                    .fixedSize()
                    .offset(y: -24)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Llama context usage")
        .accessibilityValue(usage.accessibilityText)
    }

    private func contextColor(for level: LlamaContextUsage.Level) -> Color {
        switch level {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    /// Presents the available profile choices. Delegation is a capability of a
    /// profile, not a separate route users must understand or maintain.
    private var executionRouteMenu: some View {
        Menu {
            Section("Profiles") {
                Button {
                    Task { await chatStore.selectDirectExecution() }
                } label: {
                    if chatStore.activeDynamicProfile == nil,
                       chatStore.orchestratorMode == .standalone {
                        Label("Current Model", systemImage: "checkmark")
                    } else {
                        Text("Current Model")
                    }
                }
                ForEach(chatStore.dynamicProfiles) { profile in
                    Button {
                        Task { await chatStore.selectDynamicProfile(profile.id) }
                    } label: {
                        if chatStore.activeDynamicProfileID == profile.id,
                           chatStore.orchestratorMode == .standalone {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
                Divider()
                Button("Create Profile…") {
                    chatStore.requestProfileCreation()
                }
            }

            Section("Compatibility") {
                Button {
                    Task { await chatStore.setOrchestratorMode(.orchestrator) }
                } label: {
                    if chatStore.orchestratorMode == .orchestrator {
                        Label(
                            "On-Device Delegation (Experimental)",
                            systemImage: "checkmark"
                        )
                    } else {
                        Text("On-Device Delegation (Experimental)")
                    }
                }
            }
        } label: {
            Label(executionRouteLabel, systemImage: executionRouteIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(chatStore.busy)
        .help(executionRouteHelp)
    }

    private var isDelegatingExecution: Bool {
        chatStore.orchestratorMode == .standalone
            && chatStore.activeDynamicProfile?.usesDelegation == true
    }

    private var executionRouteLabel: String {
        if chatStore.orchestratorMode == .orchestrator {
            return "On-Device Delegation"
        }
        if let profile = chatStore.activeDynamicProfile {
            return profile.usesDelegation
                ? "\(profile.name) · Delegated"
                : profile.name
        }
        return chatStore.activeBaseModelID.displayName
    }

    private var executionRouteIcon: String {
        if isDelegatingExecution {
            return "arrow.triangle.branch"
        }
        return chatStore.orchestratorMode == .orchestrator
            ? "square.2.layers.3d"
            : "laptopcomputer"
    }

    private var executionRouteHelp: String {
        if let profile = chatStore.activeDynamicProfile,
           isDelegatingExecution {
            return "\(profile.name) uses Delegate Task with its configured worker"
        }
        if chatStore.orchestratorMode == .orchestrator {
            return "Apple on-device coordinates through the experimental compatibility route"
        }
        return "The selected model handles the request directly"
    }

    @ViewBuilder
    private var branchMenu: some View {
        if chatStore.workspaceRoot.isEmpty || !chatStore.isGitRepository {
            Label("No Git repository", systemImage: "arrow.triangle.branch")
                .foregroundStyle(.tertiary)
                .help("The selected workspace is not a Git repository")
        } else {
            let label = chatStore.currentBranch.isEmpty ? "Detached HEAD" : chatStore.currentBranch

            Menu {
                if chatStore.availableBranches.isEmpty {
                    Text(chatStore.currentBranch.isEmpty
                         ? "No branches available"
                         : "No commits yet on \(chatStore.currentBranch)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(chatStore.availableBranches, id: \.self) { branch in
                        Button {
                            Task { await chatStore.switchToBranch(branch) }
                        } label: {
                            HStack {
                                Text(branch)
                                if branch == chatStore.currentBranch {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                Label(label, systemImage: "arrow.triangle.branch")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

private struct SlashCommandSuggestion: Identifiable {
    let command: String
    let insertion: String
    let description: String
    let icon: String

    var id: String { command }
}
