import SwiftUI

// MARK: - Composer Enums

enum ApprovalMode: String, CaseIterable {
    case askForApproval = "Ask for approval"
    case autoRun = "Auto-run"
}

enum ReasoningEffort: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}

// MARK: - InputFieldView — Composer input card

struct InputFieldView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.chatFontSize) private var chatFontSize
    @State private var viewModel = ComposerViewModel()
    @FocusState private var isFocused: Bool

    // Persisted preferences
    @AppStorage("approvalMode") private var approvalMode: ApprovalMode = .askForApproval
    @AppStorage("reasoningEffort") private var reasoningEffort: ReasoningEffort = .medium

    var body: some View {
        VStack(spacing: 0) {
            composerCard
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }
        .background(Color(.windowBackgroundColor))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Composer Card

    private var composerCard: some View {
        VStack(spacing: 0) {
            // ── Top section: text field + controls ──
            VStack(alignment: .leading, spacing: 12) {
                textField

                HStack(spacing: 14) {
                    attachButton
                    approvalModeMenu

                    Spacer()

                    backendMenu
                    micButton
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
        VStack(alignment: .leading, spacing: 8) {
            TextField("Do anything", text: $viewModel.messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(AppTypography.chatBody(size: chatFontSize))
                .lineLimit(1...10)
                .focused($isFocused)
                .disabled(chatStore.busy)

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
                    viewModel.messageText = suggestion.insertion
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
        let input = viewModel.messageText
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

    // MARK: - Attach Button

    private var attachButton: some View {
        Button {
            // TODO: attach files
        } label: {
            Image(systemName: "plus")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Attach files")
    }

    // MARK: - Approval Mode Menu

    private var approvalModeMenu: some View {
        Menu {
            ForEach(ApprovalMode.allCases, id: \.self) { mode in
                Button(mode.rawValue) { approvalMode = mode }
            }
        } label: {
            Label(approvalMode.rawValue, systemImage: "hand.raised")
        }
        .menuStyle(.borderlessButton)
        .font(AppTypography.control)
        .fixedSize()
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
                    Section("Backend") {
                        Button("Llama-server") {
                            chatStore.switchBackend(to: .llamaServer)
                        }
                        Button("Foundation Apple") {
                            chatStore.switchBackend(to: .foundationApple)
                        }
                        Button("Apple PCC") {
                            chatStore.switchBackend(to: .foundationServe)
                        }
                    }

                    if chatStore.activeBackend == .llamaServer {
                        Divider()
                        Section("Reasoning") {
                            ForEach(ReasoningEffort.allCases, id: \.self) { effort in
                                Button(effort.rawValue) { reasoningEffort = effort }
                            }
                        }
                    }
                } label: {
                    if chatStore.activeBackend == .llamaServer {
                        Text("Llama-server \(reasoningEffort.rawValue)")
                    } else if chatStore.activeBackend == .foundationServe {
                        Text("Apple PCC")
                    } else {
                        Text("Foundation Apple")
                    }
                }
                .menuStyle(.borderlessButton)
                .font(AppTypography.control)
                .fixedSize()
            }
        }
    }

    // MARK: - Microphone Button

    private var micButton: some View {
        Button {
            // TODO: voice input
        } label: {
            Image(systemName: "mic")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Voice input")
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button {
            if chatStore.busy {
                chatStore.interrupt()
                return
            }
            let text = viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            viewModel.reset()
            Task { await chatStore.sendMessage(text) }
        } label: {
            Image(systemName: chatStore.busy ? "stop.fill" : "arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .clipShape(Circle())
        .disabled(!chatStore.busy && !viewModel.canSend)
        .keyboardShortcut(.return, modifiers: [])
        .help(chatStore.busy ? "Stop response" : "Send message")
    }

    // MARK: - Bottom Info Bar

    private var bottomInfoBar: some View {
        HStack(spacing: 16) {
            orchestratorModeMenu
            branchMenu

            Spacer()
        }
        .font(AppTypography.metadata)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var orchestratorModeMenu: some View {
        Menu {
            ForEach(OrchestratorMode.allCases, id: \.self) { mode in
                Button(mode.rawValue) {
                    chatStore.orchestratorMode = mode
                }
            }
        } label: {
            let icon: String = chatStore.orchestratorMode == .orchestrator
                ? "square.2.layers.3d"
                : "laptopcomputer"
            Label(chatStore.orchestratorMode.rawValue, systemImage: icon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var branchMenu: some View {
        let label: String
        let icon: String
        if chatStore.workspaceRoot.isEmpty {
            label = "no repo"
            icon = "arrow.triangle.branch"
        } else if chatStore.currentBranch.isEmpty {
            label = "no repo"
            icon = "arrow.triangle.branch"
        } else {
            label = chatStore.currentBranch
            icon = "arrow.triangle.branch"
        }

        return Menu {
            if chatStore.availableBranches.isEmpty {
                Text("No branches available")
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
            Label(label, systemImage: icon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct SlashCommandSuggestion: Identifiable {
    let command: String
    let insertion: String
    let description: String
    let icon: String

    var id: String { command }
}
