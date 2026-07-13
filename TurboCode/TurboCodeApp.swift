import SwiftUI

// MARK: - TurboCode App entry point

@main
struct TurboCodeApp: App {
    @State private var chatStore: ChatStore
    @State private var settingsStore = SettingsStore()

    init() {
        let store = ChatStore()
        ChatStore.shared = store
        self.chatStore = store
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            WorkbenchSplitView()
                .environment(chatStore)
                .environment(settingsStore)
                .task {
                    // First-launch onboarding
                    await chatStore.ensureOnboarding()
                    // Restore persisted sessions
                    await chatStore.restoreSessions()
                    settingsStore.loadFromUserDefaults()
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Application menu
            CommandGroup(replacing: .appInfo) {
                Button("About TurboCode") {}
            }

            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    Task { await chatStore.createThread() }
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("New Conversation") {}
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button("Choose Workspace...") {}
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // Edit menu — standard
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {}
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {}
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            // View menu
            CommandMenu("View") {
                Button("Toggle Sidebar") {
                    chatStore.toggleLeftSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button("Toggle Terminal") {
                    chatStore.toggleTerminal()
                }
                .keyboardShortcut("j", modifiers: .command)

                Divider()

                Button("Focus Mode") {
                    // TODO
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Picker("Theme", selection: $settingsStore.theme) {
                    Text("System").tag(ThemePreference.system)
                    Text("Light").tag(ThemePreference.light)
                    Text("Dark").tag(ThemePreference.dark)
                }
            }

            // Navigate menu
            CommandMenu("Navigate") {
                Button("Chat") { chatStore.setRoute(.chat) }
                    .keyboardShortcut("1", modifiers: [.command])

                Button("Write") { chatStore.setRoute(.write) }
                    .keyboardShortcut("2", modifiers: [.command])

                Button("Schedule") { chatStore.setRoute(.schedule) }
                    .keyboardShortcut("3", modifiers: [.command])

                Button("Workflow") { chatStore.setRoute(.workflow) }
                    .keyboardShortcut("4", modifiers: [.command])
            }

            // Settings — handled by the native Settings scene below
        }

        // Native macOS Settings window
        Settings {
            SettingsTabView()
                .environment(settingsStore)
        }
    }
}
