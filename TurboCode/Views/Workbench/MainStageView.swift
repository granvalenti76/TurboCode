import SwiftUI

// MARK: - MainStageView

struct MainStageView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            switch chatStore.route {
            case .chat:
                ChatContentView()
            case .write:
                WritePlaceholderView()
            case .settings:
                SettingsTabView()
            default:
                PlaceholderIcon(icon: "square.grid.2x2", label: "Workflow")
            }
        }
    }
}
