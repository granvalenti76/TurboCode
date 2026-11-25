import SwiftUI

/// A saved chat shown read-only while another chat's turn is running.
///
/// It renders the stored blocks with the live timeline's `TurnView`, but
/// with interaction disabled: widgets such as diff or commit actions act on
/// the installed session, which here belongs to the running chat. The
/// banner offers the way back; once the turn is done, the same banner opens
/// this chat for real.
struct ConversationPreviewView: View {
    let title: String
    let blocks: [ChatBlock]
    /// Title of the chat still working, or nil once its turn has finished.
    let runningTitle: String?
    let onOpen: () -> Void
    let onReturn: () -> Void

    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            banner
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groupBlocks(blocks)) { turn in
                        TurnView(turn: turn)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                    }
                }
                .disabled(true)
                .frame(maxWidth: CGFloat(settings.maxChatWidth))
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollContentBackground(.hidden)
            footer
        }
    }

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: runningTitle == nil ? "checkmark.circle" : "eye")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(runningTitle.map { "Read-only while TurboCode works in “\($0)”" }
                     ?? "The running reply has finished")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if runningTitle != nil {
                Button("Back to Running Chat", action: onReturn)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Open This Chat", action: onOpen)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        Text(runningTitle == nil
             ? "Open this chat to continue it."
             : "You can write here once the running reply has finished.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.bar)
    }
}
