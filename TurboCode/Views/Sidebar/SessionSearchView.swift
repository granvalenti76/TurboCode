import SwiftUI

struct SessionSearchView: View {
    @State private var viewModel: SessionSearchViewModel
    @State private var isSearchFieldPresented = true

    let onSelect: (Conversation) -> Void

    init(
        conversations: [Conversation],
        onSelect: @escaping (Conversation) -> Void
    ) {
        _viewModel = State(initialValue: SessionSearchViewModel(conversations: conversations))
        self.onSelect = onSelect
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        let results = viewModel.results

        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text(viewModel.query.isEmpty ? "Recent chats" : "Search results")
                        .font(AppTypography.sectionLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(results.count == 1 ? "1 chat" : "\(results.count) chats")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                Divider()

                if results.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text("No matching chats")
                            .font(AppTypography.controlEmphasized)
                        Text("Try a session or workspace name.")
                            .font(AppTypography.sidebarMetadata)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results) { result in
                        Button {
                            onSelect(result.conversation)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: result.conversation.isArchived ? "archivebox" : "bubble.left")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)

                                Text(result.conversation.title)
                                    .font(AppTypography.sidebarTitle)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                HStack(spacing: 5) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 10))
                                    Text(result.workspaceName)
                                        .lineLimit(1)
                                }
                                .font(AppTypography.sidebarMetadata)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 150, alignment: .trailing)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(result.conversation.title), workspace \(result.workspaceName)"
                        )
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .frame(width: 440, height: 460)
        .searchable(
            text: $viewModel.query,
            isPresented: $isSearchFieldPresented,
            placement: .toolbar,
            prompt: "Sessions and workspaces"
        )
        .onAppear {
            isSearchFieldPresented = true
        }
    }
}
