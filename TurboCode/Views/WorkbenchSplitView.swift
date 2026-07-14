import SwiftUI

// MARK: - WorkbenchSplitView — native macOS navigation shell

struct WorkbenchSplitView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @AppStorage("rightSidebarWidth") private var rightWidth: Double = 360

    private let leftMinWidth: Double = 240
    private let leftMaxWidth: Double = 360
    private let mainMinWidth: Double = 560
    private let rightMinWidth: Double = 280
    private let rightMaxWidth: Double = 760

    /// Keep the window's layout constraint stable while the inspector appears.
    /// A changing root minimum makes NavigationSplitView rebalance its sidebar,
    /// which causes the project labels to shift or become clipped.
    private var workbenchMinWidth: Double {
        leftMinWidth + mainMinWidth + rightMinWidth
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: leftMinWidth,
                    ideal: 280,
                    max: leftMaxWidth
                )
        } detail: {
            HSplitView {
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
        }
        .navigationSplitViewStyle(.balanced)
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
