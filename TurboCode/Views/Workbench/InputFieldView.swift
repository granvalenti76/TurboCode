import SwiftUI

// MARK: - Composer Enums

enum ReasoningEffort: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}

// MARK: - InputFieldView — Composer input card

struct InputFieldView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.chatFontSize) private var chatFontSize
    @FocusState private var isFocused: Bool

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
        let assignment = chatStore.composerTaskAssignment(
            for: chatStore.composerInput
        )
        return VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Describe a Swift or SwiftUI task…",
                text: Binding(
                    get: { chatStore.composerInput },
                    set: { chatStore.composerInput = $0 }
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
                .onChange(of: chatStore.composerInput) { oldValue, newValue in
                    // Inspector recovery actions prepare a reviewable draft
                    // rather than executing work immediately. Focus only when
                    // text is inserted externally, not while the user types.
                    if oldValue.isEmpty && !newValue.isEmpty && !isFocused {
                        isFocused = true
                    }
                }

            if let guidance = assignment.guidance,
               !chatStore.composerInput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
                Label(guidance, systemImage: "person.2.badge.gearshape")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
                    .accessibilityLabel("Model routing: \(guidance)")
            }

            if isFocused && !slashSuggestions.isEmpty {
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
                    chatStore.composerInput = suggestion.insertion
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
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    private var slashSuggestions: [SlashCommandSuggestion] {
        let input = chatStore.composerInput
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
                            chatStore.selectBuiltInProfile(.onDevice)
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
                                chatStore.switchRemoteModel(to: model.id)
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
                                    chatStore.selectDynamicProfile(profile.id)
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
                                    chatStore.setReasoningEffort(effort)
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
                        Task { await chatStore.selectCodexProfile() }
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
                            Task {
                                await chatStore.selectCodexProfile(
                                    modelID: model.id
                                )
                            }
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
            if chatStore.busy {
                chatStore.interrupt()
                return
            }
            let text = chatStore.composerInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if chatStore.isIncompleteSkillCommand(text) {
                chatStore.composerInput = "/skill "
                isFocused = true
                return
            }
            // Clear the shared draft before starting inference so recovery
            // drafts and ordinary composer input follow the same lifecycle.
            chatStore.composerInput = ""
            Task { await chatStore.sendMessage(text) }
        } label: {
            Image(systemName: chatStore.busy ? "stop.fill" : "arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .clipShape(Circle())
        .disabled(
            !chatStore.busy
                && (
                    chatStore.composerInput
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    || chatStore.isIncompleteSkillCommand(chatStore.composerInput)
                    || !chatStore.composerTaskAssignment(
                        for: chatStore.composerInput
                    ).allowsOnDevice
                    || !chatStore.activeProfileCanSend
                )
        )
        .keyboardShortcut(.return, modifiers: [])
        .help(sendButtonHelp)
    }

    private var sendButtonHelp: String {
        if chatStore.busy { return "Stop response" }
        if let guidance = chatStore.composerTaskAssignment(
            for: chatStore.composerInput
        ).guidance {
            return guidance
        }
        if !chatStore.activeProfileCanSend {
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
        }
        .font(AppTypography.controlEmphasized)
        .foregroundStyle(.secondary)
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.vertical, compact ? 7 : 8)
    }

    /// Presents execution semantics instead of the historical storage enum.
    /// Users choose a route here; whether that route is internally represented
    /// by standalone transport mode is not product-facing information.
    private var executionRouteMenu: some View {
        Menu {
            Section("Execution Route") {
                Button {
                    chatStore.selectDirectExecution()
                } label: {
                    if isDirectExecution {
                        Label("Direct Model", systemImage: "checkmark")
                    } else {
                        Text("Direct Model")
                    }
                }
            }

            Section("Coordinator → Worker") {
                if coordinatorProfiles.isEmpty {
                    Button("Create Coordinator Profile…") {
                        chatStore.requestCoordinatorProfileCreation()
                    }
                } else {
                    ForEach(coordinatorProfiles) { profile in
                        Button {
                            chatStore.selectCoordinatorProfile(profile.id)
                        } label: {
                            if chatStore.activeDynamicProfileID == profile.id,
                               chatStore.orchestratorMode == .standalone {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                }
            }

            Section("Compatibility") {
                Button {
                    chatStore.orchestratorMode = .orchestrator
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

    private var coordinatorProfiles: [UserDynamicProfile] {
        chatStore.dynamicProfiles.filter(\.isCoordinatorProfile)
    }

    private var isCoordinatorExecution: Bool {
        chatStore.orchestratorMode == .standalone
            && chatStore.activeDynamicProfile?.isCoordinatorProfile == true
    }

    private var isDirectExecution: Bool {
        chatStore.orchestratorMode == .standalone && !isCoordinatorExecution
    }

    private var executionRouteLabel: String {
        if chatStore.orchestratorMode == .orchestrator {
            return "On-Device Delegation"
        }
        if isCoordinatorExecution {
            return "Coordinator → Worker"
        }
        return "Direct Model"
    }

    private var executionRouteIcon: String {
        if isCoordinatorExecution {
            return "arrow.triangle.branch"
        }
        return chatStore.orchestratorMode == .orchestrator
            ? "square.2.layers.3d"
            : "laptopcomputer"
    }

    private var executionRouteHelp: String {
        if let profile = chatStore.activeDynamicProfile,
           isCoordinatorExecution {
            return "\(profile.name) coordinates and delegates bounded tasks to the configured worker"
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
