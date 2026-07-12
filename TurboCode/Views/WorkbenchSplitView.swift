import SwiftUI

// MARK: - WorkbenchSplitView — 3-column macOS native split view

struct WorkbenchSplitView: View {
    @Environment(ChatStore.self) private var chatStore

    @AppStorage("leftSidebarWidth") private var leftWidth: Double = 250
    @AppStorage("rightSidebarWidth") private var rightWidth: Double = 360

    private let leftMinWidth: Double = 220
    private let leftMaxWidth: Double = 360
    private let mainMinWidth: Double = 560
    private let rightMinWidth: Double = 280
    private let rightMaxWidth: Double = 760

    var body: some View {
        HSplitView {
            if !chatStore.leftSidebarCollapsed {
                SidebarView()
                    .frame(minWidth: leftMinWidth, maxWidth: leftMaxWidth)
                    .frame(idealWidth: leftWidth)
                    .layoutPriority(0)
            }

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
        .frame(minWidth: mainMinWidth + leftMinWidth + (chatStore.rightPanelVisible ? rightMinWidth : 0))
    }
}
