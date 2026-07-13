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
    @State private var viewModel = ComposerViewModel()
    @FocusState private var isFocused: Bool

    // Persisted preferences
    @AppStorage("approvalMode") private var approvalMode: ApprovalMode = .askForApproval
    @AppStorage("reasoningEffort") private var reasoningEffort: ReasoningEffort = .medium

    private let projectName = "TurboCode"

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
        TextField("Do anything", text: $viewModel.messageText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...10)
            .focused($isFocused)
    }

    // MARK: - Attach Button

    private var attachButton: some View {
        Button {
            // TODO: attach files
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.plain)
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
                    } else {
                        Text("Foundation Apple")
                    }
                }
                .menuStyle(.borderlessButton)
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
        }
        .buttonStyle(.plain)
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button {
            let text = viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            viewModel.reset()
            Task { await chatStore.sendMessage(text) }
        } label: {
            Image(systemName: "arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .clipShape(Circle())
        .disabled(!viewModel.canSend)
        .keyboardShortcut(.return, modifiers: [])
    }

    // MARK: - Bottom Info Bar

    private var bottomInfoBar: some View {
        HStack(spacing: 16) {
            Label(projectName, systemImage: "doc.plaintext")

            orchestratorModeMenu
            branchMenu

            Spacer()
        }
        .font(.caption)
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
