import AppKit
import SwiftUI

/// Briefly reports the routing boundary above the composer without claiming
/// permanent inspector space. Detailed diagnostics remain in the Dynamic
/// control's popover for users who explicitly ask for them.
struct DynamicRoutingReceiptView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPresented = false
    @State private var displayedDecision: DynamicRoutingDecision?
    @State private var displayedToolCount = 0

    var body: some View {
        ZStack {
            if isPresented {
                receipt
                    .transition(receiptTransition)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .task(id: chatStore.dynamicRoutingPresentationRevision) {
            await presentCurrentRoutingPass()
        }
        .onChange(of: chatStore.dynamicRoutingPresentedToolNames) { _, names in
            guard isPresented else { return }
            displayedToolCount = names.count
        }
    }

    private var receipt: some View {
        HStack(spacing: 11) {
            if let decision = displayedDecision {
                Image(systemName: decision.source == .model
                      ? "square.grid.2x2"
                      : "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(decision.source == .model ? .blue : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(decision.source == .model
                         ? "\(decision.title) route"
                         : "Using profile defaults")
                        .font(.system(size: 13, weight: .semibold))
                    Text(completionSummary(for: decision))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                ProgressView()
                    .controlSize(.small)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Selecting tools")
                        .font(.system(size: 13, weight: .semibold))
                    Text("AnchorSignal is routing this request")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.97),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.separator.opacity(0.65), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
    }

    private var receiptTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .move(edge: .bottom).combined(with: .opacity)
    }

    private func completionSummary(for decision: DynamicRoutingDecision) -> String {
        let tools = displayedToolCount == 1
            ? "1 tool"
            : "\(displayedToolCount) tools"
        let duration = decision.latencyMilliseconds.formatted(
            .number.precision(.fractionLength(0))
        )
        return "\(tools) selected · \(duration) ms"
    }

    @MainActor
    private func presentCurrentRoutingPass() async {
        guard chatStore.dynamicRoutingEnabled,
              chatStore.dynamicRoutingSupported,
              !chatStore.dynamicRoutingPromptPreview.isEmpty else {
            setPresented(false)
            return
        }

        displayedDecision = nil
        displayedToolCount = 0
        setPresented(true)

        // A routing revision starts before classification and may include one
        // provider-session rebuild. Keep the receipt in its progress state
        // until the installed tool boundary is the one reported to the user.
        while chatStore.dynamicRoutingDecision == nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard !Task.isCancelled,
              let decision = chatStore.dynamicRoutingDecision else {
            setPresented(false)
            return
        }

        while chatStore.dynamicRoutingPhase != .ready, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard !Task.isCancelled else { return }

        displayedDecision = decision
        displayedToolCount = chatStore.dynamicRoutingPresentedToolNames.count

        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        setPresented(false)
    }

    @MainActor
    private func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        if reduceMotion {
            isPresented = presented
        } else {
            withAnimation(.easeInOut(duration: 0.24)) {
                isPresented = presented
            }
        }
    }
}
