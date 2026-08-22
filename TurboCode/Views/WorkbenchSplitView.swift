import SwiftUI

// MARK: - WorkbenchSplitView — native macOS navigation shell

struct WorkbenchSplitView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private let sidebarWidth: Double = 268
    private let mainMinWidth: Double = 520

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: sidebarWidth,
                    ideal: sidebarWidth,
                    max: sidebarWidth
                )
        } detail: {
            // HSplitView provides the native macOS divider and resizing
            // behavior without the constraint-looping SwiftUI inspector path.
            // Keeping both panes in one SwiftUI hierarchy also preserves every
            // environment value and avoids a custom NSHostingController bridge.
            HSplitView {
                workbenchCanvas
                    .frame(minWidth: mainMinWidth, maxWidth: .infinity)
                    .layoutPriority(1)
                    // Keep interactive chat text behind a nearly opaque edge
                    // while preserving the sidebar's native toolbar material.
                    .scrollEdgeEffectStyle(.hard, for: .top)
                    .background {
                        Color(nsColor: .windowBackgroundColor)
                            .ignoresSafeArea(edges: .top)
                    }

                if chatStore.rightPanelVisible {
                    InspectorPanelView()
                        .frame(
                            minWidth: 360,
                            idealWidth: 520,
                            maxWidth: 720,
                            maxHeight: .infinity
                        )
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        //.containerBackground(Color.white, for: .window)
        .background(alignment: .top) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: chatStore.leftSidebarCollapsed ? 0 : sidebarWidth)
                Color(nsColor: .windowBackgroundColor)
            }
            .frame(height: 52)
            .ignoresSafeArea(edges: .top)
        }
        .sheet(isPresented: customProfilesPresented) {
            CustomProfilesSheet()
        }
        // Keep this sheet on the stable workbench root. A receipt row lives in
        // a LazyVStack and may be rebuilt while a response or session changes.
        .sheet(item: diffPatchReviewBinding) { presentation in
            DiffPatchReviewSheet(patch: presentation.patch)
        }
        .onChange(of: chatStore.leftSidebarCollapsed, initial: true) { _, collapsed in
            let target: NavigationSplitViewVisibility = collapsed ? .detailOnly : .all
            guard columnVisibility != target else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = target
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            chatStore.leftSidebarCollapsed = visibility == .detailOnly
        }
        .onChange(of: chatStore.workspaceRoot) { _, workspaceRoot in
            // A pseudo-terminal belongs to exactly one workspace. Closing the
            // project also tears down its utility area and child shell.
            if workspaceRoot.isEmpty {
                chatStore.terminalPresented = false
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    chatStore.toggleRightPanel(.activity)
                } label: {
                    Image(systemName: "person.2")
                }
                .help(
                    chatStore.rightPanelMode == .activity
                        ? "Hide delegated task activity"
                        : "Show delegated task activity"
                )
                .accessibilityLabel("Delegated task activity")

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        chatStore.toggleTerminal()
                    }
                } label: {
                    Image(systemName: chatStore.terminalPresented ? "terminal.fill" : "terminal")
                }
                .disabled(chatStore.workspaceRoot.isEmpty || chatStore.route != .chat)
                .help(
                    chatStore.workspaceRoot.isEmpty
                        ? "Choose a workspace to open its terminal"
                        : chatStore.terminalPresented
                            ? "Close project terminal"
                            : "Open project terminal"
                )
                .accessibilityLabel(
                    chatStore.terminalPresented
                        ? "Close project terminal"
                        : "Open project terminal"
                )

                Button {
                    chatStore.toggleRightPanel(.changes)
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(
                    chatStore.rightPanelMode == .changes
                        ? "Hide changes"
                        : "Show changes"
                )
            }
        }
        // The workbench is the reusable UI composition boundary used by the
        // app, previews, and hosted layout tests. Child views observe narrow
        // projections even when no TurboCodeApp scene constructed the shell.
        .environment(chatStore.composerCommandRouter)
        .environment(chatStore.composerViewModel)
        .environment(chatStore.presentationViewModel)
    }

    /// Keeps the terminal at the workbench-layout level rather than embedding
    /// it in the composer. `VSplitView` supplies the same native, draggable
    /// horizontal divider used by macOS utility and debug areas.
    @ViewBuilder
    private var workbenchCanvas: some View {
        if chatStore.terminalPresented,
           let configuration = EmbeddedTerminalLaunchConfiguration.resolve(
               workspacePath: chatStore.workspaceRoot
           ) {
            VSplitView {
                MainStageView()
                    .frame(minHeight: 280, maxHeight: .infinity)
                    .layoutPriority(1)

                EmbeddedTerminalPanel(configuration: configuration) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        chatStore.terminalPresented = false
                    }
                }
                .id(configuration.workingDirectory)
                .frame(minHeight: 140, idealHeight: 250, maxHeight: 600)
            }
        } else {
            MainStageView()
        }
    }

    private var customProfilesPresented: Binding<Bool> {
        Binding(
            get: { chatStore.isCustomProfilesPresented },
            set: { chatStore.isCustomProfilesPresented = $0 }
        )
    }

    private var diffPatchReviewBinding: Binding<DiffPatchReviewPresentation?> {
        Binding(
            get: { chatStore.diffPatchReviewPresentation },
            set: { newValue in
                if newValue == nil {
                    chatStore.dismissDiffPatchReview()
                } else {
                    chatStore.diffPatchReviewPresentation = newValue
                }
            }
        )
    }

}

private struct CustomProfilesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Custom Profiles", systemImage: "person.crop.rectangle.stack")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()
            SkillsView()
        }
        .frame(minWidth: 960, idealWidth: 1080, minHeight: 580, idealHeight: 680)
    }
}
