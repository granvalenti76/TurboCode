import SwiftUI

/// A decorative GPU signal for one task. The surrounding inspector owns all
/// execution semantics; the waveform and particles are never measured telemetry.
struct AgentActivityCyberdeckView: View {
    let startedAt: Date
    let isFinished: Bool
    let statusTitle: String
    let statusSymbol: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(
                minimumInterval: 1.0 / 30,
                paused: reduceMotion || !isVisible || scenePhase != .active
            )) { timeline in
                // Ambient motion intentionally continues after task completion;
                // the label alone conveys execution state. Double shader time
                // for faster flow without increasing the 30 fps rendering budget.
                // Reduce Motion still uses a fixed composition.
                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                let time = reduceMotion ? 2.4 : elapsed * 2
                RoundedRectangle(cornerRadius: 10)
                    .fill(ShaderLibrary.agentCyberdeck(
                        .float2(Float(geometry.size.width), Float(geometry.size.height)),
                        .float(Float(time.truncatingRemainder(dividingBy: 3_600))),
                        .float(isFinished ? 0.90 : 1),
                        .float(contrast == .increased ? 1 : 0),
                        .float(colorScheme == .light ? 1 : 0)
                    ))
                    .overlay(alignment: .topLeading) {
                        Label(statusTitle, systemImage: statusSymbol)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.top, 13)
                    }
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}
