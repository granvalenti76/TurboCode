import SwiftUI

// MARK: - WorkbenchSplitView — 3-column macOS native split view

struct WorkbenchSplitView: View {
    @Environment(ChatStore.self) private var chatStore

    @AppStorage("leftSidebarWidth") private var leftWidth: Double = 250
    @AppStorage("rightSidebarWidth") private var rightWidth: Double = 360

    private let leftMinWidth: Double = 220
    private let leftMaxWidth: Double = 360
    private let mainMinWidth: Double = 560
    private let rightMinWidth: Double = 280
    private let rightMaxWidth: Double = 760

    var body: some View {
        HSplitView {
            if !chatStore.leftSidebarCollapsed {
                SidebarView()
                    .frame(minWidth: leftMinWidth, maxWidth: leftMaxWidth)
                    .frame(idealWidth: leftWidth)
                    .layoutPriority(0)
            }

            MainStageView()
                .frame(minWidth: mainMinWidth)
                .layoutPriority(1)

            if chatStore.rightPanelVisible {
                InspectorPanelView()
                    .frame(minWidth: rightMinWidth, maxWidth: rightMaxWidth)
                    .frame(idealWidth: rightWidth)
                    .layoutPriority(0)
            }
        }
        .frame(minWidth: mainMinWidth + leftMinWidth + (chatStore.rightPanelVisible ? rightMinWidth : 0))
    }
}

// MARK: - MainStageView

struct MainStageView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            TopBarView()
            Divider()
            switch chatStore.route {
            case .chat:
                ChatContentView()
            case .write:
                WritePlaceholderView()
            case .settings:
                SettingsTabView()
            default:
                PlaceholderIcon(icon: "square.grid.2x2", label: "Workflow")
            }
        }
    }
}

// MARK: - Top Bar

struct TopBarView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        HStack(spacing: 8) {
            Spacer()

            workspaceButton

            inspectorToggleButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
    }

    private var inspectorToggleButton: some View {
        Button {
            chatStore.toggleRightPanel(.changes)
        } label: {
            Image(systemName: chatStore.rightPanelVisible ? "sidebar.right" : "sidebar.right")
                .font(.system(size: 11))
                .foregroundStyle(chatStore.rightPanelVisible ? .primary : .tertiary)
        }
        .buttonStyle(.plain)
        .help("Toggle inspector panel")
    }

    private var workspaceButton: some View {
        Button {
            chatStore.chooseWorkspace()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: chatStore.workspaceRoot.isEmpty ? "folder" : "folder.fill")
                    .font(.system(size: 11))
                Text(chatStore.workspaceLabel)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(chatStore.workspaceRoot.isEmpty ? "Choose a workspace" : chatStore.workspaceRoot)
    }
}

// MARK: - Chat Content (empty state + timeline + composer)

struct ChatContentView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            RuntimeBannerView()

            if chatStore.blocks.isEmpty && chatStore.liveAssistant.isEmpty && chatStore.liveReasoning.isEmpty {
                // Empty state — centered
                VStack(spacing: 8) {
                    Spacer()
                    Text("What should we build in TurboCode?")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("Ask anything or describe what you want to create")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                // Message timeline
                MessageTimelineView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 16) {
            VStack(spacing: 0) {
                if chatStore.terminalOpen {
                    Divider()
                    TerminalPlaceholderView()
                        .frame(height: chatStore.terminalHeight)
                }
                ComposerAreaView()
            }
        }
    }
}

// MARK: - Composer Area (input card)

struct ComposerAreaView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            // Input card (text field + controls + info bar in one unified card)
            InputFieldView()
        }
        .background(Color(.windowBackgroundColor))
    }
}



// MARK: - Composer Input Card (text field + controls row + bottom info bar)

struct InputFieldView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var messageText: String = ""
    @FocusState private var isFocused: Bool

    @AppStorage("approvalMode") private var approvalMode: ApprovalMode = .askForApproval
    @AppStorage("reasoningEffort") private var reasoningEffort: ReasoningEffort = .medium
    @AppStorage("workMode") private var workMode: WorkMode = .local
    @AppStorage("selectedBranch") private var selectedBranch: String = "main"

    private let projectName = "TurboCode"
    private let availableBranches = ["main", "feat/direct-llm-executor", "develop"]

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top section: text field + controls ──
            VStack(alignment: .leading, spacing: 12) {
                TextField("Do anything", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...10)
                    .focused($isFocused)

                HStack(spacing: 14) {
                    // Attach button
                    Button {
                        // TODO: attach files
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)

                    // Approval mode
                    Menu {
                        ForEach(ApprovalMode.allCases, id: \.self) { mode in
                            Button(mode.rawValue) { approvalMode = mode }
                        }
                    } label: {
                        Label(approvalMode.rawValue, systemImage: "hand.raised")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Spacer()

                    // Model picker (backend + reasoning effort)
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

                    // Microphone
                    Button {
                        // TODO: voice input
                    } label: {
                        Image(systemName: "mic")
                    }
                    .buttonStyle(.plain)

                    // Send button
                    Button {
                        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        messageText = ""
                        Task { await chatStore.sendMessage(text) }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: []) 
                }
            }
            .padding(16)

            Divider()

            // ── Bottom info bar ──
            HStack(spacing: 16) {
                Label(projectName, systemImage: "doc.plaintext")

                Menu {
                    ForEach(WorkMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) { workMode = mode }
                    }
                } label: {
                    Label(workMode.rawValue, systemImage: "laptopcomputer")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    ForEach(availableBranches, id: \.self) { branch in
                        Button(branch) { selectedBranch = branch }
                    }
                } label: {
                    Label(selectedBranch, systemImage: "arrow.triangle.branch")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Empty State Icon Helper

struct PlaceholderIcon: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(label)
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Missing Views

struct WritePlaceholderView: View {
    var body: some View {
        PlaceholderIcon(icon: "doc.text.magnifyingglass", label: "Write Workspace")
    }
}

struct TerminalPlaceholderView: View {
    var body: some View {
        VStack {
            HStack {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text("Terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            Spacer()
            Text("Terminal output will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(.background)
    }
}

struct RuntimeBannerView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        if chatStore.runtimeStatus != .ready {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if chatStore.runtimeStatus == .disconnected {
                    Button("Connect") {
                        chatStore.runtimeStatus = .connecting
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(statusColor.opacity(0.08))
        }
    }

    private var statusColor: Color {
        switch chatStore.runtimeStatus {
        case .disconnected: return .red
        case .connecting: return .orange
        case .ready: return .green
        case .error: return .red
        }
    }

    private var statusText: String {
        switch chatStore.runtimeStatus {
        case .disconnected: return "Runtime disconnected"
        case .connecting: return "Connecting to runtime..."
        case .ready: return ""
        case .error: return "Runtime error"
        }
    }
}
