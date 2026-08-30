import SwiftUI

// MARK: - WorkbenchSplitView — native macOS navigation shell

struct WorkbenchSplitView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var hoveredToolbarButton: ToolbarButtonID?

    private enum ToolbarButtonID: Hashable {
        case editorialDesk
        case delegatedTask
        case terminal
        case changes
    }

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
            // Keep the three workbench surfaces together like Notes' centered
            // mode control. Native Liquid Glass owns the translucency and
            // edge treatment; each action still delegates to existing state.
            ToolbarItem(placement: .principal) {
                HStack(spacing: 4) {
                    toolbarPillButton(
                        id: .editorialDesk,
                        icon: "newspaper",
                        label: "Editorial desk",
                        help: chatStore.workspaceRoot.isEmpty
                            ? "Choose a workspace to open the editorial desk"
                            : "Open editorial desk",
                        isActive: chatStore.editorialDeskPresentation != nil,
                        isDisabled: chatStore.workspaceRoot.isEmpty
                    ) {
                        chatStore.presentEditorialDesk()
                    }

                    toolbarPillButton(
                        id: .delegatedTask,
                        icon: "person.2",
                        label: "Delegated task activity",
                        help: chatStore.rightPanelMode == .activity
                            ? "Hide delegated task activity"
                            : "Show delegated task activity",
                        isActive: chatStore.rightPanelMode == .activity
                    ) {
                        chatStore.toggleRightPanel(.activity)
                    }

                    toolbarPillButton(
                        id: .terminal,
                        icon: chatStore.terminalPresented ? "terminal.fill" : "terminal",
                        label: chatStore.terminalPresented
                            ? "Close project terminal"
                            : "Open project terminal",
                        help: chatStore.workspaceRoot.isEmpty
                            ? "Choose a workspace to open its terminal"
                            : chatStore.terminalPresented
                                ? "Close project terminal"
                                : "Open project terminal",
                        isActive: chatStore.terminalPresented,
                        isDisabled: chatStore.workspaceRoot.isEmpty || chatStore.route != .chat
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            chatStore.toggleTerminal()
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }

            ToolbarItem(placement: .primaryAction) {
                toolbarPillButton(
                    id: .changes,
                    icon: "sidebar.right",
                    label: "Changes",
                    help: chatStore.rightPanelMode == .changes
                        ? "Hide changes"
                        : "Show changes",
                    isActive: chatStore.rightPanelMode == .changes
                ) {
                    chatStore.toggleRightPanel(.changes)
                }
                .padding(5)
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

    private func toolbarPillButton(
        id: ToolbarButtonID,
        icon: String,
        label: String,
        help: String,
        isActive: Bool,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredToolbarButton == id && !isDisabled

        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .background(
            isActive
                ? Color.accentColor.opacity(0.14)
                : isHovered
                    ? Color.primary.opacity(0.10)
                    : .clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .disabled(isDisabled)
        .onHover { hovering in
            hoveredToolbarButton = hovering && !isDisabled ? id : nil
        }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
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
