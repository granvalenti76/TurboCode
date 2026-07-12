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

enum WorkMode: String, CaseIterable {
    case local = "Work locally"
    case cloud = "Work in cloud"
}

// MARK: - InputFieldView — Composer input card

struct InputFieldView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var viewModel = ComposerViewModel()
    @FocusState private var isFocused: Bool

    // Persisted preferences
    @AppStorage("approvalMode") private var approvalMode: ApprovalMode = .askForApproval
    @AppStorage("reasoningEffort") private var reasoningEffort: ReasoningEffort = .medium
    @AppStorage("workMode") private var workMode: WorkMode = .local
    @AppStorage("selectedBranch") private var selectedBranch: String = "main"

    private let projectName = "TurboCode"
    private let availableBranches = ["main", "feat/direct-llm-executor", "develop"]

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

            workModeMenu
            branchMenu

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var workModeMenu: some View {
        Menu {
            ForEach(WorkMode.allCases, id: \.self) { mode in
                Button(mode.rawValue) { workMode = mode }
            }
        } label: {
            Label(workMode.rawValue, systemImage: "laptopcomputer")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var branchMenu: some View {
        Menu {
            ForEach(availableBranches, id: \.self) { branch in
                Button(branch) { selectedBranch = branch }
            }
        } label: {
            Label(selectedBranch, systemImage: "arrow.triangle.branch")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
