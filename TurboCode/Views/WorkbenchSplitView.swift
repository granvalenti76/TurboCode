import SwiftUI

// MARK: - WorkbenchSplitView — 3-column macOS native split view

/// The primary layout container: resizable sidebar | main content | optional inspector.
/// Persists widths to UserDefaults. Respects HIG split-view behavior with drag handles.
struct WorkbenchSplitView: View {
    @Environment(ChatStore.self) private var chatStore

    // Persisted widths
    @AppStorage("leftSidebarWidth") private var leftWidth: Double = 280
    @AppStorage("rightSidebarWidth") private var rightWidth: Double = 360

    private let leftMinWidth: Double = 280
    private let leftMaxWidth: Double = 480
    private let mainMinWidth: Double = 560
    private let rightMinWidth: Double = 280
    private let rightMaxWidth: Double = 760

    var body: some View {
        HSplitView {
            // Left sidebar
            if !chatStore.leftSidebarCollapsed {
                SidebarView()
                    .frame(minWidth: leftMinWidth, maxWidth: leftMaxWidth)
                    .frame(idealWidth: leftWidth, maxWidth: leftMaxWidth)
                    .layoutPriority(0)
            }

            // Main content area: toolbar + timeline + composer
            MainStageView()
                .frame(minWidth: mainMinWidth)
                .layoutPriority(1)

            // Right inspector panel
            if chatStore.rightPanelVisible {
                InspectorPanelView()
                    .frame(minWidth: rightMinWidth, maxWidth: rightMaxWidth)
                    .frame(idealWidth: rightWidth, maxWidth: rightMaxWidth)
                    .layoutPriority(0)
            }
        }
        .frame(minWidth: mainMinWidth + leftMinWidth + (chatStore.rightPanelVisible ? rightMinWidth : 0))
    }
}

// MARK: - MainStageView: toolbar + timeline + composer

struct MainStageView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar with model picker and right panel buttons
            WorkbenchToolbar()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.bar)

            Divider()

            // Based on route, show different content
            switch chatStore.route {
            case .chat:
                ChatContentView()
            case .write:
                WritePlaceholderView()
            case .settings:
                SettingsTabView()
            case .plugins:
                PluginsPlaceholderView()
            case .claw:
                ClawPlaceholderView()
            case .schedule:
                SchedulePlaceholderView()
            case .workflow:
                WorkflowPlaceholderView()
            }
        }
    }
}

// MARK: - ChatContentView: timeline + composer + terminal

struct ChatContentView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            // Runtime status banner
            RuntimeBannerView()

            // Message timeline — main scrollable area
            MessageTimelineView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Floating composer
            FloatingComposerView()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.bar)

            // Terminal drawer (optional)
            if chatStore.terminalOpen {
                Divider()
                TerminalPlaceholderView()
                    .frame(height: chatStore.terminalHeight)
            }
        }
    }
}

// MARK: - Toolbar

struct WorkbenchToolbar: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        HStack(spacing: 6) {
            routePicker
            Spacer()
            workspaceButton
            rightPanelButtons
        }
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
                    .frame(maxWidth: 150, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(chatStore.workspaceRoot.isEmpty ? .tertiary : .primary)
        }
        .buttonStyle(.plain)
        .help(chatStore.workspaceRoot.isEmpty ? "Choose a workspace folder" : chatStore.workspaceRoot)
        .contextMenu {
            if !chatStore.workspaceRoot.isEmpty {
                Button("Clear workspace") { chatStore.clearWorkspace() }
            }
        }
    }

    // MARK: - Route Picker

    private var routePicker: some View {
        HStack(spacing: 2) {
            ForEach(RouteTab.allCases, id: \.self) { tab in
                Button {
                    chatStore.setRoute(tab.route)
                } label: {
                    Label(tab.label, systemImage: tab.icon)
                        .font(.system(size: 12))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(tab.label)
                .frame(width: 28, height: 22)
                .background(
                    chatStore.route == tab.route
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
        }
        .padding(4)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Right Panel Buttons

    private var rightPanelButtons: some View {
        HStack(spacing: 4) {
            ToolbarIconButton(
                icon: "list.clipboard",
                tooltip: "Todo",
                isActive: chatStore.rightPanelMode == .todo
            ) {
                chatStore.toggleRightPanel(.todo)
            }

            ToolbarIconButton(
                icon: "doc.text",
                tooltip: "Changes",
                isActive: chatStore.rightPanelMode == .changes
            ) {
                chatStore.toggleRightPanel(.changes)
            }

            ToolbarIconButton(
                icon: "globe",
                tooltip: "Browser",
                isActive: chatStore.rightPanelMode == .browser
            ) {
                chatStore.toggleRightPanel(.browser)
            }

            ToolbarIconButton(
                icon: "terminal",
                tooltip: "Terminal",
                isActive: chatStore.terminalOpen
            ) {
                chatStore.toggleTerminal()
            }
        }
    }
}

// MARK: - Toolbar Icon Button

struct ToolbarIconButton: View {
    let icon: String
    let tooltip: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 22)
        }
        .buttonStyle(.borderless)
        .help(tooltip)
        .background(
            isActive ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
    }
}

// MARK: - Route tabs

private enum RouteTab: String, CaseIterable {
    case chat
    case write
    case schedule
    case workflow

    var route: AppRoute {
        switch self {
        case .chat: return .chat
        case .write: return .write
        case .schedule: return .schedule
        case .workflow: return .workflow
        }
    }

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .write: return "Write"
        case .schedule: return "Schedule"
        case .workflow: return "Workflow"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "message"
        case .write: return "pencil"
        case .schedule: return "clock"
        case .workflow: return "square.grid.2x2"
        }
    }
}

// MARK: - Runtime Banner

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
                        // TODO: start Kun runtime
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

// MARK: - Placeholder views for other routes

struct WritePlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Write Workspace")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Markdown editor with AI inline completion")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct PluginsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Plugin Marketplace")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct ClawPlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("IM Channels (Claw)")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct SchedulePlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Scheduled Tasks")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct WorkflowPlaceholderView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Workflow Editor")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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
