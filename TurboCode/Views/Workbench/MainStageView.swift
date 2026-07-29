import SwiftUI

// MARK: - MainStageView

struct MainStageView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            switch chatStore.route {
            case .chat:
                ChatContentView()
            case .tools:
                ToolsView()
            case .skills:
                // Custom Profiles is presented modally over the current route;
                // this fallback keeps restored legacy state on a working canvas.
                ChatContentView()
            }
        }
    }
}
