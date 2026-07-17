import SwiftUI

// MARK: - WorkbenchSplitView — native macOS navigation shell

struct WorkbenchSplitView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var routeBeforeCustomProfiles: AppRoute = .chat

    private let sidebarWidth: Double = 268
    private let mainMinWidth: Double = 520

    /// Keep the window's layout constraint stable while the inspector appears.
    /// A changing root minimum makes NavigationSplitView rebalance its sidebar,
    /// which causes the project labels to shift or become clipped.
    private var workbenchMinWidth: Double { sidebarWidth + mainMinWidth }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: sidebarWidth,
                    ideal: sidebarWidth,
                    max: sidebarWidth
                )
        } detail: {
            ZStack(alignment: .trailing) {
                MainStageView()
                    .frame(minWidth: mainMinWidth)

                if chatStore.rightPanelVisible {
                    InspectorPanelView()
                        .frame(width: 420)
                        .background(.background)
                        .overlay(alignment: .leading) {
                            Divider()
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .background {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea(edges: .top)
            }
            .clipped()
            .animation(.easeInOut(duration: 0.18), value: chatStore.rightPanelVisible)
        }
        .navigationSplitViewStyle(.balanced)
        .containerBackground(.regularMaterial, for: .window)
        .background(alignment: .top) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: chatStore.leftSidebarCollapsed ? 0 : sidebarWidth)
                Color(nsColor: .windowBackgroundColor)
            }
            .frame(height: 52)
            .ignoresSafeArea(edges: .top)
        }
        .frame(minWidth: workbenchMinWidth)
        .sheet(isPresented: customProfilesPresented) {
            CustomProfilesSheet()
        }
        .onChange(of: chatStore.route) { previousRoute, route in
            guard route == .skills, previousRoute != .skills else { return }
            routeBeforeCustomProfiles = previousRoute
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
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                WorkspaceToolbarMenu()

                Button {
                    chatStore.toggleRightPanel(.changes)
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(chatStore.rightPanelVisible ? "Hide changes" : "Show changes")
            }
        }
    }

    private var customProfilesPresented: Binding<Bool> {
        Binding(
            get: { chatStore.route == .skills },
            set: { presented in
                guard !presented, chatStore.route == .skills else { return }
                chatStore.setRoute(routeBeforeCustomProfiles)
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
