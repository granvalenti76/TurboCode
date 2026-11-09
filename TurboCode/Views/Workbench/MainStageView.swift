import SwiftUI

// MARK: - MainStageView

struct MainStageView: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(spacing: 0) {
            switch chatStore.route {
            case .chat:
                // The expanded Artifacts preview is drawn over the chat rather
                // than in its place: the conversation view stays alive, so
                // expanding and collapsing cannot disturb the session.
                ZStack {
                    ChatContentView()
                    if chatStore.coworkArtifactsExpanded {
                        CoworkArtifactsInspectorView(isExpanded: true)
                            .background(Color(nsColor: .windowBackgroundColor))
                    }
                }
            case .tools:
                ToolsView()
            case .artifacts:
                CoworkArtifactsLibraryView()
            case .skills:
                // Custom Profiles is presented modally over the current route;
                // this fallback keeps restored legacy state on a working canvas.
                ChatContentView()
            }
        }
    }
}
