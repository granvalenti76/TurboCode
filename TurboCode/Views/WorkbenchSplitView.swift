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
        // Keep the editorial feature behind one reversible integration point:
        // removing the module only removes this toolbar action and its sheet.
        .sheet(item: editorialDeskPresentationBinding) { presentation in
            EditorialDeskSheet(
                workspaceRoot: chatStore.workspaceRoot,
                initialDraftRelativePath: presentation.draftRelativePath,
                dependencies: chatStore.editorialDeskAssembly.dependencies(
                    for: chatStore.workspaceRoot
                )
            )
        }
        // Keep this sheet on the stable workbench root. A receipt row lives in
        // a LazyVStack and may be rebuilt while a response or session changes.
        .sheet(item: diffPatchReviewBinding) { presentation in
            DiffPatchReviewSheet(patch: presentation.patch)
        }
        // Transcript inspection belongs to the window-level conversation
        // document, not to a recycled row inside the lazy message timeline.
        .sheet(item: transcriptSheetBinding) { presentation in
            TranscriptSheet(threadID: presentation.id)
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
        .onChange(of: chatStore.workspaceRoot) { previousRoot, workspaceRoot in
            // A pseudo-terminal belongs to exactly one workspace. Closing the
            // project also tears down its utility area and child shell.
            if workspaceRoot.isEmpty {
                chatStore.terminalPresented = false
            }
            // Draft paths are workspace-relative. A project switch invalidates
            // the active presentation even when both roots are non-empty.
            if previousRoot != workspaceRoot {
                chatStore.dismissEditorialDesk()
            }
        }
        .toolbar {
            // Expose each control to the native toolbar so macOS owns symbol
            // sizing, spacing, and Liquid Glass grouping. Fixed label frames
            // and outer padding inflate the group inside the unified title bar.
            ToolbarItemGroup(placement: .principal) {
                Button {
                    chatStore.presentEditorialDesk()
                } label: {
                    Label("Editorial desk", systemImage: "doc.richtext")
                }
                .labelStyle(.iconOnly)
                .disabled(chatStore.workspaceRoot.isEmpty)
                .help(chatStore.workspaceRoot.isEmpty
                    ? "Choose a workspace to open the editorial desk"
                    : "Open editorial desk")

                // These surfaces can remain open independently. Native toggles
                // express their state without a custom selection background or
                // the mutually exclusive behavior of a segmented picker.
                Toggle(isOn: Binding(
                    get: { chatStore.rightPanelMode == .activity },
                    set: { isPresented in
                        if isPresented != (chatStore.rightPanelMode == .activity) {
                            chatStore.toggleRightPanel(.activity)
                        }
                    }
                )) {
                    Label("Delegated task activity", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(chatStore.rightPanelMode == .activity
                    ? "Hide delegated task activity"
                    : "Show delegated task activity")

                Toggle(isOn: Binding(
                    get: { chatStore.terminalPresented },
                    set: { isPresented in
                        if isPresented != chatStore.terminalPresented {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                chatStore.toggleTerminal()
                            }
                        }
                    }
                )) {
                    Label("Project terminal", systemImage: "terminal")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .disabled(chatStore.workspaceRoot.isEmpty || chatStore.route != .chat)
                .help(chatStore.workspaceRoot.isEmpty
                    ? "Choose a workspace to open its terminal"
                    : chatStore.terminalPresented
                        ? "Close project terminal"
                        : "Open project terminal")
            }

            // Match the central group with native sizing and glass. Transcript
            // opens a sheet; Changes is a persistent inspector visibility state.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    chatStore.presentTranscript()
                } label: {
                    Label("Show transcript", systemImage: "text.document")
                }
                .labelStyle(.iconOnly)
                .disabled(chatStore.activeThreadId == nil || chatStore.route != .chat)
                .help(chatStore.activeThreadId == nil
                    ? "Start a conversation to inspect its transcript"
                    : "Show transcript")

                Toggle(isOn: Binding(
                    get: { chatStore.rightPanelMode == .changes },
                    set: { isPresented in
                        if isPresented != (chatStore.rightPanelMode == .changes) {
                            chatStore.toggleRightPanel(.changes)
                        }
                    }
                )) {
                    Label("Changes", systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help(chatStore.rightPanelMode == .changes
                    ? "Hide changes"
                    : "Show changes")
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

    private var editorialDeskPresentationBinding: Binding<EditorialDeskPresentation?> {
        Binding(
            get: { chatStore.editorialDeskPresentation },
            set: { newValue in
                if newValue == nil {
                    chatStore.dismissEditorialDesk()
                } else {
                    chatStore.editorialDeskPresentation = newValue
                }
            }
        )
    }

    private var transcriptSheetBinding: Binding<TranscriptSheetPresentation?> {
        Binding(
            get: { chatStore.transcriptSheetPresentation },
            set: { newValue in
                if newValue == nil {
                    chatStore.dismissTranscript()
                } else {
                    chatStore.transcriptSheetPresentation = newValue
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
        .frame(
            minWidth: 1_160,
            idealWidth: 1_280,
            minHeight: 640,
            idealHeight: 760
        )
    }
}
