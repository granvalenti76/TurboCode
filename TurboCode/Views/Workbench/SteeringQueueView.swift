import SwiftUI

/// Transient queue and recovery controls for steering awaiting delivery.
/// Confirmed requests remain in runtime history and the transcript, but no
/// longer occupy the composer. Queue admission alone must not dismiss them.
struct SteeringQueueView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.chatFontSize) private var chatFontSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var requests: [SteeringRequest] {
        chatStore.steeringRequests
            .filter { $0.state != .removed && $0.state != .delivered }
            .sorted { $0.sequence < $1.sequence }
    }

    /// Mirrors `SteeringCoordinator.claimAtToolBoundary`: Codex steers through
    /// its own protocol and the on-device model only at the end of the turn.
    private var deliversAtToolBoundary: Bool {
        chatStore.busy
            && chatStore.activeBackend != .codex
            && chatStore.activeBackend != .foundationApple
    }

    /// Row text follows the chat font preference but stays a step smaller
    /// than the conversation, like the composer's own controls.
    private var rowFont: Font {
        AppTypography.chatBody(size: max(13, chatFontSize - 3))
    }

    var body: some View {
        let requests = requests
        let hasQueued = requests.contains { $0.state == .queued }
        // Keep the animation owner mounted across an empty queue so both the
        // first insertion and the last removal animate the panel's space.
        VStack(spacing: 0) {
            if !requests.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    header(count: requests.count, hasQueued: hasQueued)
                    ForEach(requests) { request in
                        requestRow(request)
                            .transition(queueTransition)
                    }
                }
                .composerShelf()
                .transition(queueTransition)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.25),
            value: requests.map(\.id)
        )
    }

    private func header(count: Int, hasQueued: Bool) -> some View {
        HStack(spacing: 6) {
            Text("Steering")
                .font(AppTypography.sectionLabel)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if count > 1 {
                Text("\(count)")
                    .font(AppTypography.metadata.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if hasQueued, deliversAtToolBoundary {
                // States when queued steering will reach the model, so the
                // user can tell waiting from Send Now.
                Text("· after the next tool call")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.tertiary)
                    .help(
                        "Queued steering reaches the model after the next tool call, "
                            + "without interrupting the turn. If no more tools run, "
                            + "it is delivered when the turn ends."
                    )
            }
            Spacer(minLength: 8)
            if hasQueued {
                Button("Send Now") {
                    Task { await chatStore.sendSteeringNow() }
                }
                .buttonStyle(.borderless)
                .font(AppTypography.controlEmphasized)
                .help("Interrupt the turn and deliver the queued steering now")
            }
        }
    }

    private var queueTransition: AnyTransition {
        // A fixed upward entrance stays consistent as the queue grows; moving
        // by the full panel height would make larger batches travel farther.
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 16))
    }

    private func requestRow(_ request: SteeringRequest) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if request.state == .delivering {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: icon(for: request.state))
                        .font(AppTypography.control)
                        .foregroundStyle(color(for: request.state))
                }
            }
            .frame(width: 16)
            .accessibilityHidden(true)

            Text(request.text)
                .font(rowFont)
                .foregroundStyle(AppTypography.chatForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(request.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(request.text), \(label(for: request.state))")

            // A plain queued row needs no label: the header already says
            // when it will be delivered. Other states are worth naming.
            if request.state != .queued {
                Text(label(for: request.state))
                    .font(AppTypography.metadata)
                    .foregroundStyle(color(for: request.state))
                    .accessibilityHidden(true)
            }
            if request.state == .paused || request.state == .failed {
                Button("Resume") {
                    Task { await chatStore.recoverSteering(request.id) }
                }
                .buttonStyle(.borderless)
                .font(AppTypography.controlEmphasized)
            }
            if [.queued, .paused, .failed].contains(request.state) {
                Button {
                    Task { await chatStore.removeSteering(request.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(AppTypography.metadata.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove steering: \(request.text)")
                .help("Remove steering")
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(for state: SteeringRequestState) -> String {
        switch state {
        case .queued: "clock"
        case .delivering: "arrow.triangle.2.circlepath"
        case .delivered: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .uncertain: "questionmark.circle"
        case .paused: "pause.circle"
        case .removed: "xmark.circle"
        }
    }

    private func color(for state: SteeringRequestState) -> Color {
        switch state {
        case .failed, .uncertain: .orange
        case .delivered: .green
        default: .secondary
        }
    }

    private func label(for state: SteeringRequestState) -> String {
        switch state {
        case .queued: "Queued"
        case .delivering: "Sending…"
        case .delivered: "Sent"
        case .failed: "Delivery failed"
        case .uncertain: "Delivery unconfirmed"
        case .paused: "Paused"
        case .removed: "Removed"
        }
    }
}
