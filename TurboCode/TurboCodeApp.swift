import SwiftUI
import AppKit

// MARK: - TurboCode App entry point

@main
struct TurboCodeApp: App {
    @NSApplicationDelegateAdaptor(TurboCodeAppDelegate.self) private var appDelegate
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
                // An external event, such as a click on a reply notification,
                // would otherwise make the WindowGroup open a second main
                // window on the same shared ChatStore. The open window claims
                // every such event; the notification delegate then shows the
                // chat in it.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
                    chatStore.attachCowork(settingsStore.cowork)
                    chatStore.attachReplyNotifications(settings: settingsStore)
                    appDelegate.cowork = settingsStore.cowork
                    chatStore.restoreActiveDomain(allowsCowork: settingsStore.cowork.isAvailable)
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

            // View menu. macOS already provides a View menu for the window
            // toolbar and full screen, so these items join it through its
            // sidebar group; a CommandMenu("View") adds a second menu with the
            // same title. Replacing the group also keeps a single sidebar
            // toggle, the one that drives the app's own sidebar state.
            CommandGroup(replacing: .sidebar) {
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

        WindowGroup("Plugin Widget", id: "plugin-widget", for: String.self) { $blockID in
            if let blockID,
               let widget = chatStore.detachedPluginWidget(for: blockID) {
                PluginWidgetView(
                    blockID: blockID,
                    widget: widget,
                    isDetachedWindow: true
                )
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .environment(chatStore)
            } else {
                ContentUnavailableView(
                    "Widget non disponibile",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Il widget è stato chiuso o rimosso dalla conversazione.")
                )
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 680)

        // Native macOS Settings window
        Settings {
            SettingsRootView()
                .environment(chatStore)
                .environment(settingsStore)
        }
    }
}

// MARK: - Termination

/// Stops the Studio VM before the app exits.
///
/// Without this the process exited with the guest still running, so its
/// writable layer was never unmounted; repeated unclean exits corrupted that
/// layer and made every later boot fail. Quitting waits for the stop, bounded
/// by `CoworkStore.stopForTermination`. A forced kill (Xcode's Stop) skips
/// this path; the layer's journal covers that case.
@MainActor
final class TurboCodeAppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the Studio store is attached; nil means nothing to stop.
    var cowork: CoworkStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let cowork else { return .terminateNow }
        Task { @MainActor in
            await cowork.stopForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
