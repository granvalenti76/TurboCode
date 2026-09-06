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

    private var controlFont: Font {
        AppTypography.chatBody(size: max(13, chatFontSize - 3))
    }

    var body: some View {
        let requests = requests
        // Keep the animation owner mounted across an empty queue so both the
        // first insertion and the last removal animate the panel's space.
        VStack(spacing: 0) {
            if !requests.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Label("Steering", systemImage: "text.bubble")
                            .font(controlFont.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("\(requests.count)")
                            .font(controlFont.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        if requests.contains(where: { $0.state == .queued }) {
                            Button("Invia ora", systemImage: "arrow.up") {
                                Task { await chatStore.sendSteeringNow() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .font(controlFont.weight(.medium))
                        }
                    }

                    ForEach(requests) { request in
                        requestRow(request)
                            .transition(queueTransition)
                    }
                }
                .padding(16)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
                .padding(.bottom, 10)
                .transition(queueTransition)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.25),
            value: requests.map(\.id)
        )
    }

    private var queueTransition: AnyTransition {
        // A fixed upward entrance stays consistent as the queue grows; moving
        // by the full panel height would make larger batches travel farther.
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 16))
    }

    private func requestRow(_ request: SteeringRequest) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if request.state == .delivering {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon(for: request.state))
                        .font(AppTypography.chatBody(size: chatFontSize))
                        .foregroundStyle(color(for: request.state))
                }
            }
            .frame(width: 24, height: 28)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(request.text)
                    .font(AppTypography.chatBody(size: chatFontSize))
                    .lineLimit(2)
                    .help(request.text)
                Text(label(for: request.state))
                    .font(controlFont)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            if request.state == .paused || request.state == .failed {
                Button("Riprendi") {
                    Task { await chatStore.recoverSteering(request.id) }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .font(controlFont.weight(.medium))
            }
            if [.queued, .paused, .failed].contains(request.state) {
                Button {
                    Task { await chatStore.removeSteering(request.id) }
                } label: {
                    Image(systemName: "xmark")
                        .font(controlFont)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Rimuovi steering: \(request.text)")
                .help("Rimuovi steering")
            }
        }
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
        case .queued: "In attesa"
        case .delivering: "Invio in corso…"
        case .delivered: "Inviato"
        case .failed: "Invio non riuscito"
        case .uncertain: "Consegna da verificare"
        case .paused: "In pausa"
        case .removed: "Rimosso"
        }
    }
}
