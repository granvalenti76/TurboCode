import SwiftUI

// MARK: - WorkbenchSplitView — native macOS navigation shell

struct WorkbenchSplitView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private let sidebarWidth: Double = 280
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
        .containerBackground(.ultraThinMaterial.opacity(0.62), for: .window)
        .background(alignment: .top) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: sidebarWidth)
                Color(nsColor: .windowBackgroundColor)
            }
            .frame(height: 52)
            .ignoresSafeArea(edges: .top)
        }
        .frame(minWidth: workbenchMinWidth)
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
}
