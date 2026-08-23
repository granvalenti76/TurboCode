import SwiftUI
import AppKit

// MARK: - TurboCode App entry point

@main
struct TurboCodeApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var chatStore: ChatStore
    @State private var settingsStore = SettingsStore()
    @State private var approvalStore = ApprovalStore()

    init() {
        let store = ChatStore()
        ChatStore.shared = store
        self.chatStore = store
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            WorkbenchSplitView()
                .navigationTitle("")
                .environment(chatStore)
                .environment(settingsStore)
                .environment(approvalStore)
                .environment(\.chatFontSize, CGFloat(settingsStore.fontSize))
                .preferredColorScheme(settingsStore.theme.colorScheme)
                .task {
                    approvalStore.start()
                    // First-launch onboarding
                    await chatStore.ensureOnboarding()
                    // Restore persisted sessions
                    await chatStore.restoreSessions()
                    settingsStore.loadFromUserDefaults()
                    // Settings persistence does not reach into the chat facade.
                    // App composition explicitly synchronizes runtime inputs so
                    // TurboCodeCore can remain independent of global UI stores.
                    await chatStore.applyAgentTuning(settingsStore.agentTuning)
                    await chatStore.reloadRemoteModels()
                }
        }
        .windowStyle(.titleBar)
        // Keep the native window title visible while evaluating the toolbar
        // layout; this is a reversible presentation-only change.
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 650)
        .commands {
            // Application menu
            CommandGroup(replacing: .appInfo) {
                Button("About TurboCode") {
                    // Use the system panel so version, keyboard behavior, and
                    // accessibility remain owned by macOS.
                    NSApplication.shared.orderFrontStandardAboutPanel()
                }
            }

            // File menu
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    Task { await chatStore.createThread() }
                }
                .keyboardShortcut("n", modifiers: [.command])

                Divider()

                Button("Choose Workspace…") {
                    chatStore.chooseWorkspace()
                }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // View menu
            CommandMenu("View") {
                Button("Toggle Sidebar") {
                    chatStore.toggleLeftSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command])

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

                Button("Custom Profiles") { chatStore.setRoute(.skills) }
                    .keyboardShortcut("2", modifiers: [.command])

                Button("Tools") { chatStore.setRoute(.tools) }
                    .keyboardShortcut("3", modifiers: [.command])
            }

#if DEBUG
            CommandMenu("Developer") {
                Button("Run 5 Editing Benchmarks") {
                    Task { await chatStore.runActiveEditingBenchmark() }
                }
                .disabled(chatStore.busy || chatStore.benchmarkRunning)

                Button("Print Tool Failure Summary") {
                    Task { await chatStore.printToolFailureSummary() }
                }

                Button("Print Runtime Baseline") {
                    Task { await chatStore.printRuntimeBaselineSummary() }
                }

                Button("On-Device Statistics") {
                    // A dedicated window keeps live developer diagnostics out
                    // of the product navigation and conversation state.
                    openWindow(id: "on-device-statistics")
                }

                Button("Llama Statistics") {
                    openWindow(id: "llama-statistics")
                }

                if let benchmarkStatus = chatStore.benchmarkStatus {
                    Divider()
                    Button(benchmarkStatus) {}
                        .disabled(true)
                }
            }
#endif

            // Settings — handled by the native Settings scene below
        }

#if DEBUG
        Window("On-Device Statistics", id: "on-device-statistics") {
            OnDeviceStatisticsView()
        }
        .defaultSize(width: 880, height: 700)

        Window("Llama Statistics", id: "llama-statistics") {
            LlamaStatisticsView()
        }
        .defaultSize(width: 720, height: 520)
#endif

        // Native macOS Settings window
        Settings {
            SettingsTabView()
                .environment(chatStore)
                .environment(settingsStore)
        }
    }
}
