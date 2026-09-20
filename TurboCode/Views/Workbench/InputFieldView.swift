import SwiftUI

// MARK: - InputFieldView — Composer input card

struct InputFieldView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(ComposerCommandRouter.self) private var commandRouter
    @Environment(ComposerViewModel.self) private var composer
    @Environment(ChatPresentationViewModel.self) private var presentation
    @Environment(\.chatFontSize) private var chatFontSize
    @FocusState private var isFocused: Bool
    @State private var composerSelection: TextSelection?
    @State private var selectedSlashCommandIndex = 0
    @State private var showsDynamicRouting = false

    let compact: Bool

    // Persisted preferences
    @AppStorage("reasoningEffort") private var reasoningEffort: ReasoningEffort = .medium

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        VStack(spacing: 0) {
            SteeringQueueView()
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
                    if chatStore.busy {
                        queueButton
                        stopButton
                    } else {
                        sendButton
                    }
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
                selection: $composerSelection,
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .font(AppTypography.chatBody(size: chatFontSize))
                .lineLimit(1...10)
                .focused($isFocused)
                .padding(.bottom, compact ? 12 : 18)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        isFocused = true
                    }
                )
                .onChange(of: composer.messageText) { oldValue, newValue in
                    // A changed query describes a new result set; keeping the
                    // previous row selected could execute the wrong command.
                    selectedSlashCommandIndex = 0
                    if newValue.isEmpty {
                        composerSelection = nil
                    }
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
        if press.key == .return,
           press.modifiers.contains(.shift),
           press.modifiers.intersection([.command, .control, .option]).isEmpty {
            insertComposerNewline()
            return .handled
        }

        if press.key == .return,
           press.modifiers.intersection([.command, .control, .option]).isEmpty {
            if !chatStore.busy, !slashSuggestions.isEmpty {
                executeSelectedSlashCommand()
                return .handled
            }
            sendComposerInput()
            return .handled
        }

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

    private func insertComposerNewline() {
        let currentText = composer.messageText
        let replacementRange: Range<String.Index>

        switch composerSelection?.indices {
        case .selection(let range):
            replacementRange = range
        case .multiSelection(let ranges):
            // A plain composer normally has one selection. If SwiftUI exposes
            // multiple ranges, use the first instead of losing the key press.
            replacementRange = ranges.ranges.first
                ?? currentText.endIndex..<currentText.endIndex
        case nil:
            replacementRange = currentText.endIndex..<currentText.endIndex
        @unknown default:
            // Future SwiftUI selection forms must degrade to insertion at the
            // end instead of making the composer uncompilable after an SDK bump.
            replacementRange = currentText.endIndex..<currentText.endIndex
        }

        let insertionOffset = currentText.distance(
            from: currentText.startIndex,
            to: replacementRange.lowerBound
        )
        var updatedText = currentText
        updatedText.replaceSubrange(replacementRange, with: "\n")
        let insertionPoint = updatedText.index(
            updatedText.startIndex,
            offsetBy: insertionOffset + 1
        )

        composer.messageText = updatedText
        composerSelection = TextSelection(insertionPoint: insertionPoint)
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
                description: "List Markdown skills",
                icon: "square.stack.3d.up"
            ),
            SlashCommandSuggestion(
                command: "/mcp",
                insertion: "/mcp",
                description: "List on-demand MCP integrations",
                icon: "network"
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
                description: "Reload profiles and TypeScript plugins",
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
        Menu {
            ForEach(ComposerProfileMenu.defaults) { id in
                defaultProfileMenu(id)
            }
            if !chatStore.dynamicProfiles.isEmpty {
                Divider()
                ForEach(chatStore.dynamicProfiles.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }) { profile in
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
            }
        } label: {
            if chatStore.activeModelOffersReasoningControl {
                Text("\(chatStore.composerModel) · \(activeReasoningLabel)")
            } else {
                Text(chatStore.composerModel)
            }
        }
        .menuStyle(.borderlessButton)
        .font(AppTypography.controlEmphasized)
        .fixedSize()
        .disabled(chatStore.busy || chatStore.isDynamicRouting)
    }

    /// Native submenus support hover and keyboard navigation without changing
    /// the provider until a reasoning option is explicitly chosen.
    private func defaultProfileMenu(_ id: ProfileBaseModelID) -> some View {
        let isSelected = chatStore.activeDynamicProfileID == nil
            && chatStore.activeBaseModelID == id
            && chatStore.orchestratorMode == .standalone
        let options = ComposerProfileMenu.reasoningOptions(for: id, models: chatStore.remoteModels)
        let available = id.remoteModelID.map { remoteID in
            chatStore.remoteModels.contains { $0.id == remoteID && $0.enabled }
        } ?? true
        return Menu {
            if id == .codex {
                // Until a catalog has been loaded, Automatic selects the
                // provider default instead of inventing supported levels.
                let codexOptions = chatStore.codexPreferredModel?.supportedReasoningEfforts ?? []
                if codexOptions.isEmpty {
                    Button("Automatic") {
                        Task { await chatStore.selectBuiltInProfile(.codex) }
                    }
                } else {
                    ForEach(codexOptions, id: \.reasoningEffort) { option in
                        Button {
                            Task {
                                await chatStore.selectBuiltInProfile(.codex, codexReasoning: option.reasoningEffort)
                            }
                        } label: {
                            reasoningOptionLabel(
                                option.reasoningEffort.displayName,
                                selected: isSelected && chatStore.codexReasoningEffort == option.reasoningEffort
                            )
                        }
                    }
                }
            } else if options.isEmpty {
                Button {
                    Task { await chatStore.selectBuiltInProfile(id) }
                } label: {
                    reasoningOptionLabel("Automatic", selected: isSelected)
                }
            } else {
                ForEach(options, id: \.self) { effort in
                    Button {
                        Task { await chatStore.selectBuiltInProfile(id, reasoning: effort) }
                    } label: {
                        reasoningOptionLabel(
                            effort.rawValue,
                            selected: isSelected && effectiveReasoningEffort == effort
                        )
                    }
                }
            }
        } label: {
            reasoningOptionLabel(
                ComposerProfileMenu.name(for: id, models: chatStore.remoteModels),
                selected: isSelected
            )
        }
        .disabled(!available)
        .help(available ? "Choose a reasoning level" : "Enable this provider in Settings")
    }

    @ViewBuilder
    private func reasoningOptionLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var activeReasoningLabel: String {
        if chatStore.activeBackend == .codex {
            return chatStore.codexReasoningEffort.displayName
        }
        return effectiveReasoningEffort.rawValue
    }

    /// Preserve the local X-High preference while presenting the equivalent
    /// native High selection when the user temporarily switches providers.
    private var effectiveReasoningEffort: ReasoningEffort {
        guard reasoningEffort == .xhigh else { return reasoningEffort }
        switch chatStore.activeBackend {
        case .llamaServer, .foundationApple:
            return .xhigh
        case .foundationServe, .premium, .codex:
            return .high
        }
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button {
            sendComposerInput()
        } label: {
            Image(systemName: "arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .clipShape(Circle())
        .disabled(
            chatStore.isDynamicRouting || composer.messageText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                || (
                    commandRouter.isIncompleteSkillCommand(composer.messageText)
                    || commandRouter.isIncompleteTaskCommand(composer.messageText)
                    || (
                        !chatStore.activeProfileCanSend
                            && !commandRouter.isLocalCommand(composer.messageText)
                    )
                )
            )
        .help(sendButtonHelp)
    }

    private func sendComposerInput() {
        guard !chatStore.isDynamicRouting else { return }
        if chatStore.busy {
            let text = composer.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commandRouter.isLocalCommand(text),
                  !commandRouter.isIncompleteSkillCommand(text),
                  !commandRouter.isIncompleteTaskCommand(text) else {
                chatStore.showSteeringUnavailableMessage()
                return
            }
            enqueueComposerSteering()
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

    private func enqueueComposerSteering() {
        let text = composer.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let generation = composer.editGeneration
        Task {
            let result = await chatStore.enqueueSteering(text)
            guard case .accepted = result,
                  composer.editGeneration == generation else { return }
            composer.reset()
        }
    }

    private var stopButton: some View {
        Button {
            Task { await chatStore.interrupt() }
        } label: {
            Image(systemName: "stop.fill")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .clipShape(Circle())
        .help("Stop response")
    }

    private var queueButton: some View {
        Button("Queue") {
            enqueueComposerSteering()
        }
        .buttonStyle(.borderless)
        .disabled(
            composer.messageText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
        .help("Queue steering for the next controlled step")
    }

    private var sendButtonHelp: String {
        if chatStore.busy { return "Queue steering" }
        if !chatStore.activeProfileCanSend
            && !commandRouter.isLocalCommand(composer.messageText) {
            return "Wait for Codex to connect or sign in first"
        }
        return "Send message"
    }

    // MARK: - Bottom Info Bar

    private var bottomInfoBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                branchMenu
                dynamicRoutingControl
                Spacer(minLength: 20)
                ComposerStatisticsView(
                    statistics: presentation.composerSessionStatistics
                )
                .fixedSize(horizontal: true, vertical: false)
            }

            // Give the statistics their own row before compressing their
            // contents; an open inspector must not clip usage or the branch.
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    branchMenu
                    dynamicRoutingControl
                    Spacer(minLength: 0)
                }
                ComposerStatisticsView(
                    statistics: presentation.composerSessionStatistics
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(AppTypography.control)
        .padding(.horizontal, compact ? 16 : 20)
        .padding(.vertical, compact ? 7 : 8)
    }

    @ViewBuilder
    private var dynamicRoutingControl: some View {
        if chatStore.dynamicRoutingSupported {
            HStack(spacing: 7) {
                Text("Tools")
                    .foregroundStyle(.secondary)

                Picker("Tool selection", selection: Binding(
                    get: { chatStore.dynamicRoutingEnabled },
                    set: { enabled in
                        Task { await chatStore.setDynamicRoutingEnabled(enabled) }
                    }
                )) {
                    Text("Profile").tag(false)
                    Text("Auto").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 126)
            }
            .controlSize(.small)
            .fixedSize()
            .disabled(chatStore.busy || chatStore.isDynamicRouting)
            .help("Use profile tools or choose tools automatically for each request")
            .accessibilityHint("Profile uses the configured tool set. Auto selects tools for each request.")
            if chatStore.dynamicRoutingEnabled {
                Button {
                    showsDynamicRouting.toggle()
                } label: {
                    HStack(spacing: 4) {
                        if chatStore.isDynamicRouting {
                            ProgressView().controlSize(.mini)
                            Text("Routing…")
                        } else {
                            Image(systemName: chatStore.dynamicRoutingDecision?.source == .fallback
                                  ? "exclamationmark.triangle" : "square.grid.2x2")
                            Text("\(chatStore.dynamicRoutingPresentedToolNames.count) tools")
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show the latest routing decision and loaded tools")
                .accessibilityLabel("Automatic tool selection details")
                .popover(isPresented: $showsDynamicRouting, arrowEdge: .bottom) {
                    dynamicRoutingDetails
                }
            }
        }
    }

    private var dynamicRoutingDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Automatic tool selection · Experimental", systemImage: "square.grid.2x2")
                .font(.headline)
            if chatStore.isDynamicRouting {
                Text("Classifying your request before sending it to the model…")
            } else if let decision = chatStore.dynamicRoutingDecision {
                Text(decision.title).font(.title3.bold())
                Text(decision.summary).foregroundStyle(.secondary)
                LabeledContent("Classifier", value: decision.source == .model ? "AnchorSignal" : "Profile defaults")
                LabeledContent("Routing time", value: "\(decision.latencyMilliseconds.formatted(.number.precision(.fractionLength(0)))) ms")
                if decision.source == .model {
                    LabeledContent("Similarity", value: decision.topScore.formatted(.number.precision(.fractionLength(3))))
                    LabeledContent("Margin", value: decision.margin.formatted(.number.precision(.fractionLength(3))))
                    Text("Similarity is a ranking score, not a confidence probability.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let reason = decision.fallbackReason {
                    Text("AnchorSignal unavailable: \(reason)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Selected tools (\(chatStore.dynamicRoutingPresentedToolNames.count))").font(.subheadline.bold())
                if chatStore.dynamicRoutingPresentedToolNames.isEmpty {
                    Text("No tools for this turn.").foregroundStyle(.secondary)
                } else {
                    ForEach(chatStore.dynamicRoutingPresentedToolNames, id: \.self) { name in
                        Text(name).font(.system(.caption, design: .monospaced))
                    }
                }
                Text("The session is reused when the tool set stays the same. Changing tools rebuilds the session.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Waiting for your first prompt. The session starts with no tools; a package is selected before each turn.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(18)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
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
            .lineLimit(1)
            .truncationMode(.middle)
            .help(label)
        }
    }
}

/// Compact, read-only usage summary for the composer footer.
///
/// The fallback keeps all metrics visible in narrow windows instead of
/// shrinking them into unreadable labels or hiding provider gaps.
private struct ComposerStatisticsView: View {
    let statistics: ComposerSessionStatistics?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            compactLayout
            stackedLayout
        }
        .font(AppTypography.control)
        .accessibilityElement(children: .contain)
    }

    private var compactLayout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            contextGroup
            metricGroup(label: "Cache hit", value: cacheHitText, detail: cacheDetail)
            metricGroup(
                label: "Session tokens",
                value: totalTokensText,
                detail: usageDetail
            )
        }
    }

    private var stackedLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            contextGroup
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    metricGroup(
                        label: "Cache hit",
                        value: cacheHitText,
                        detail: cacheDetail
                    )
                    metricGroup(
                        label: "Session tokens",
                        value: totalTokensText,
                        detail: usageDetail
                    )
                }
                VStack(alignment: .leading, spacing: 8) {
                    metricGroup(
                        label: "Cache hit",
                        value: cacheHitText,
                        detail: cacheDetail
                    )
                    metricGroup(
                        label: "Session tokens",
                        value: totalTokensText,
                        detail: usageDetail
                    )
                }
            }
        }
    }

    private var contextGroup: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Context")
                .foregroundStyle(.secondary)
            Text(contextPercentageText)
                .foregroundStyle(statistics?.context == nil ? .secondary : .primary)
                .fontWeight(.medium)
                .monospacedDigit()
            if let context = statistics?.context {
                Text(context.usedTokens.formatted(.number) + " / "
                     + context.contextSize.formatted(.number))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        // Reserve the same space with and without a sample so the text baseline
        // stays still. An overlay lets the text determine the track's width.
        .padding(.bottom, 8)
        .overlay(alignment: .bottomLeading) {
            if let context = statistics?.context {
                Gauge(value: context.fraction, in: 0...1) { Text("Context capacity") }
                    .gaugeStyle(ComposerCapacityGaugeStyle(color: contextColor(for: context.fraction)))
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(contextHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Context")
        .accessibilityValue(contextAccessibilityText)
    }

    private func metricGroup(
        label: String,
        value: String,
        detail: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(value == "—" ? .secondary : .primary)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(detail)
    }

    private var contextPercentageText: String {
        guard let context = statistics?.context else { return "—" }
        let percentage = Int((context.fraction * 100).rounded())
        return String(percentage) + "%"
    }

    private var contextAccessibilityText: String {
        guard let context = statistics?.context else {
            return "Not available from provider"
        }
        let percentage = Int((context.fraction * 100).rounded())
        return String(percentage) + " percent, "
            + context.usedTokens.formatted(.number) + " of "
            + context.contextSize.formatted(.number) + " tokens"
    }

    private var contextHelp: String {
        guard let statistics, statistics.context != nil else {
            return "Not available from provider"
        }
        return contextAccessibilityText
    }

    private var cacheHitText: String {
        guard let fraction = statistics?.cacheHitFraction else { return "—" }
        let value = String(Int((fraction * 100).rounded())) + "%"
        guard statistics?.hasPartialCacheCoverage == true else { return value }
        return value + " partial"
    }

    private var totalTokensText: String {
        guard let statistics, let total = statistics.totalTokens else { return "—" }
        let value = total.formatted(.number)
        return statistics.hasPartialUsage ? value + " partial" : value
    }

    private var cacheDetail: String {
        guard let statistics,
              let cached = statistics.cachedInputTokens,
              statistics.cacheHitFraction != nil else {
            return "Not available from provider"
        }
        let coverage = statistics.hasPartialCacheCoverage ? "; partial" : ""
        return cacheHitText + " cache hit, "
            + cached.formatted(.number) + " cached input tokens" + coverage
    }

    private var usageDetail: String {
        guard let statistics, let total = statistics.totalTokens else {
            return "Not available from provider"
        }
        let coverage = statistics.hasPartialUsage ? "; partial" : ""
        return total.formatted(.number) + " input and output tokens" + coverage
    }

    private func contextColor(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.60: .green
        case ..<0.80: .orange
        default: .red
        }
    }
}

/// The native capacity style has an intrinsic height that a small frame does
/// not reduce. Draw the track at its actual height to avoid overlapping text,
/// while retaining Gauge's capacity semantics and system pressure colors.
private struct ComposerCapacityGaugeStyle: GaugeStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .frame(width: geometry.size.width * configuration.value)
                }
        }
        .frame(height: 3)
    }
}

private struct SlashCommandSuggestion: Identifiable {
    let command: String
    let insertion: String
    let description: String
    let icon: String

    var id: String { command }
}
