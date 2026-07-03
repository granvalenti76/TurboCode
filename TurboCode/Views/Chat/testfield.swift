import SwiftUI

// MARK: 

enum ApprovalMode: String, CaseIterable {
    case askForApproval = "Ask for approval"
    case autoRun = "Auto-run"
}

enum ReasoningEffort: String, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
}

enum WorkMode: String, CaseIterable {
    case local = "Work locally"
    case cloud = "Work in cloud"
}

// MARK: - ViewModel

@MainActor
@Observable
final class ComposerViewModel {

    var draft = ""
    var approvalMode: ApprovalMode = .askForApproval
    var reasoningEffort: ReasoningEffort = .medium
    var workMode: WorkMode = .local

    let modelVersion = "GPT-5"
    let projectName = "Codechat"
    var selectedBranch = "feat/direct-llm-executor"
    let availableBranches = ["main", "feat/direct-llm-executor"]

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() async {
        guard canSend else { return }
        draft = ""
    }
}

// MARK: - View

struct ComposerView: View {

    @State private var viewModel = ComposerViewModel()
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {

            VStack(alignment: .leading, spacing: 12) {

                TextField("Do anything", text: $viewModel.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...10)
                    .focused($isFocused)

                HStack(spacing: 14) {

                    Button {
                        // TODO
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button("Ask for approval") {
                            viewModel.approvalMode = .askForApproval
                        }
                        Button("Auto-run") {
                            viewModel.approvalMode = .autoRun
                        }
                    } label: {
                        Label(viewModel.approvalMode.rawValue, systemImage: "hand.raised")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Spacer()

                    Menu {
                        Button("Low") { viewModel.reasoningEffort = .low }
                        Button("Medium") { viewModel.reasoningEffort = .medium }
                        Button("High") { viewModel.reasoningEffort = .high }
                    } label: {
                        Text("\(viewModel.modelVersion) \(viewModel.reasoningEffort.rawValue)")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button {
                        // TODO
                    } label: {
                        Image(systemName: "mic")
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await viewModel.send() }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .disabled(!viewModel.canSend)
                }
            }
            .padding(16)

            Divider()

            HStack(spacing: 16) {
                Label(viewModel.projectName, systemImage: "doc.plaintext")

                Menu {
                    Button("Work locally") { viewModel.workMode = .local }
                    Button("Work in cloud") { viewModel.workMode = .cloud }
                } label: {
                    Label(viewModel.workMode.rawValue, systemImage: "laptopcomputer")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    ForEach(viewModel.availableBranches, id: \.self) { branch in
                        Button(branch) { viewModel.selectedBranch = branch }
                    }
                } label: {
                    Label(viewModel.selectedBranch, systemImage: "arrow.triangle.branch")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }
}

// MARK: - Preview

#Preview {
    ComposerView()
        .padding(40)
        .frame(width: 700)
        .background(Color(nsColor: .windowBackgroundColor))
}
