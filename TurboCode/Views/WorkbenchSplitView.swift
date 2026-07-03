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
            Button("Get Plus") {
                // TODO: upsell flow
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                LinearGradient(colors: [Color(red: 0.4, green: 0.2, blue: 0.9), Color(red: 0.6, green: 0.3, blue: 1.0)], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(red: 0.5, green: 0.25, blue: 0.95).opacity(0.3), lineWidth: 1)
            )

            Spacer()

            workspaceButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.windowBackgroundColor))
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
        ZStack(alignment: .bottom) {
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

            // Composer area (overlay at bottom)
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

// MARK: - Composer Area (warning + input + bottom bar)

struct ComposerAreaView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            // Warning banner
            WarningBannerView()

            // Input field
            InputFieldView()

            // Bottom toolbar
            ComposerToolbarView()
        }
        .background(Color(.windowBackgroundColor))
    }
}

// MARK: - Warning Banner

struct WarningBannerView: View {
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("You're out of Codex messages")
                    .font(.system(size: 11, weight: .semibold))
                Text("Your rate limit resets on Jul 18, 2026, 7:55 AM. To continue using TurboCode, upgrade to Plus today.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Upgrade") {}
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(.black, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
                .padding(4)
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

// MARK: - Input Field

struct InputFieldView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var messageText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Do anything", text: $messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .focused($isFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

            Button {
                let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                messageText = ""
                Task { await chatStore.sendMessage(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(messageText.trimmingCharacters(in: .whitespaces).isEmpty ? .quaternary : .primary)
            }
            .buttonStyle(.plain)
            .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Composer Bottom Toolbar

struct ComposerToolbarView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        HStack(spacing: 6) {
            // Attach button
            Button {} label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            // Approval mode
            HStack(spacing: 2) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 10))
                Text("Ask for approval")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            // Model picker
            Menu {
                Button("Auto") {}
                Button("DeepSeek") {}
                Button("GPT-4o") {}
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                    Text("5.5 Medium")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            // Microphone
            Button {} label: {
                Image(systemName: "mic")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
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
