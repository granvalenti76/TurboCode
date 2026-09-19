import AppKit
import SwiftUI

/// Replays the real Dynamic routing result as one compact procedure. The GPU
/// layer owns continuous scan, flow, and impact light; SwiftUI overlays only
/// readable prompt, package, and tool labels from the runtime snapshot.
struct DynamicRoutingInspectorView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.scenePhase) private var scenePhase

    @State private var scanStartedAt = Date()
    @State private var routeStartedAt: Date?
    @State private var presentedPrompt = ""
    @State private var presentedDecision: DynamicRoutingDecision?
    @State private var presentedTools: [String] = []
    @State private var isVisible = false

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(
                minimumInterval: 1.0 / 60.0,
                paused: reduceMotion || !isVisible || scenePhase != .active
            )) { timeline in
                let now = reduceMotion ? Date.distantFuture : timeline.date
                let routeProgress = routeProgress(at: now)
                let scanProgress = scanProgress(at: now)
                procedure(
                    size: geometry.size,
                    time: now.timeIntervalSinceReferenceDate,
                    scanProgress: scanProgress,
                    routeProgress: routeProgress
                )
            }
        }
        .task(id: chatStore.dynamicRoutingPresentationRevision) {
            await prepareCurrentRoutingStory()
        }
        .onChange(of: chatStore.dynamicRoutingPresentedToolNames) { _, names in
            guard presentedDecision != nil else { return }
            presentedTools = names
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private func procedure(
        size: CGSize,
        time: TimeInterval,
        scanProgress: CGFloat,
        routeProgress: CGFloat
    ) -> some View {
        let stageSize = CGSize(
            width: max(1, size.width - 20),
            height: max(1, size.height - 20)
        )
        let promptY = min(128, stageSize.height * 0.18)
        let candidatesY = promptY + 92
        let coreHeight = systemPromptHeight(
            in: stageSize.height,
            routeProgress: routeProgress
        )
        let coreY = systemPromptY(
            in: stageSize.height,
            coreHeight: coreHeight,
            routeProgress: routeProgress
        )

        return ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.clear)

            routingHeader(routeProgress: routeProgress)
                .frame(width: max(230, stageSize.width - 28))
                .position(x: stageSize.width / 2, y: 30)

            promptSurface(
                width: stageSize.width,
                scanProgress: scanProgress,
                routeProgress: routeProgress
            )
            .position(x: stageSize.width / 2, y: promptY)

            candidateRail(width: stageSize.width, routeProgress: routeProgress)
                .position(x: stageSize.width / 2, y: candidatesY)

            selectedPackage(routeProgress: routeProgress)
                .position(packagePosition(
                    progress: routeProgress,
                    width: stageSize.width,
                    sourceY: candidatesY + 46,
                    targetY: coreY - 75
                ))

            packetLayer(
                size: stageSize,
                progress: routeProgress,
                sourceY: candidatesY + 72,
                targetY: coreY - 72
            )

            systemPromptCore(routeProgress: routeProgress)
                .frame(width: max(246, stageSize.width - 28), height: coreHeight)
                .position(x: stageSize.width / 2, y: coreY)

            routingFooter(routeProgress: routeProgress)
                .frame(width: max(230, stageSize.width - 28))
                .position(
                    x: stageSize.width / 2,
                    y: min(stageSize.height - 18, coreY + coreHeight / 2 + 22)
                )

            // Metal renders the continuous motion that visually joins the
            // semantic scan, package flight, and system-prompt impact.
            RoundedRectangle(cornerRadius: 20)
                .fill(ShaderLibrary.anchorSignalRouting(
                    .float2(Float(stageSize.width), Float(stageSize.height)),
                    .float(Float(time.truncatingRemainder(dividingBy: 3_600))),
                    .float(Float(scanProgress)),
                    .float(Float(routeProgress)),
                    .float(Float(coreY / stageSize.height)),
                    .float(colorScheme == .light ? 1 : 0),
                    .float(contrast == .increased ? 1 : 0)
                ))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: stageSize.width, height: stageSize.height)
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.primary.opacity(colorScheme == .light ? 0.08 : 0.14), lineWidth: 1)
        }
        .position(x: size.width / 2, y: size.height / 2)
    }

    private func routingHeader(routeProgress: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(.cyan)
                .frame(width: 24, height: 24)
                .background(.cyan.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("AnchorSignal")
                    .font(.system(size: 13, weight: .black))
                    .tracking(1.15)
                Text(stageCaption(routeProgress: routeProgress))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Circle()
                    .fill(routeProgress >= 1 ? .green : .orange)
                    .frame(width: 5, height: 5)
                Text(routeProgress >= 1 ? "READY" : "ROUTING")
                    .font(.system(size: 10, weight: .black))
            }
            .foregroundStyle(routeProgress >= 1 ? .green : .orange)
        }
    }

    private func promptSurface(
        width: CGFloat,
        scanProgress: CGFloat,
        routeProgress: CGFloat
    ) -> some View {
        let exit = smoothstep(0.02, 0.18, routeProgress)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 13)
                .fill(.thinMaterial)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("PROMPT / SEMANTIC SCAN")
                        .font(.system(size: 10, weight: .black))
                        .tracking(0.8)
                        .foregroundStyle(.cyan)
                    Spacer()
                    Text("\(Int(scanProgress * 100))%")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }

                Text(presentedPrompt.isEmpty ? "Waiting for prompt…" : presentedPrompt)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(width: max(238, width - 28), height: 104)
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(.cyan.opacity(0.18 + (1 - exit) * 0.24), lineWidth: 1)
        }
        .scaleEffect(1 - exit * 0.035)
        .offset(y: -exit * 18)
        .opacity(1 - exit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Prompt semantic scan")
        .accessibilityValue(presentedPrompt)
    }

    private func candidateRail(width: CGFloat, routeProgress: CGFloat) -> some View {
        let exit = smoothstep(0.06, 0.24, routeProgress)
        return HStack(spacing: max(4, min(10, (width - 260) / 9))) {
            ForEach(DynamicToolPackage.allCases) { package in
                let selected = presentedDecision?.package == package
                VStack(spacing: 3) {
                    Image(systemName: packageIcon(package))
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 31, height: 27)
                        .foregroundStyle(selected ? .orange : .secondary)
                        .background(
                            selected ? Color.orange.opacity(0.12) : Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    selected ? Color.orange.opacity(0.55) : Color.primary.opacity(0.08),
                                    lineWidth: 1
                                )
                        }
                    Text(package.title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(selected ? .orange : .secondary)
                        .lineLimit(1)
                }
                .frame(width: 39)
                .scaleEffect(selected ? 1.08 : 1)
                .opacity(selected ? 1 : 0.64)
            }
        }
        .frame(width: max(238, width - 24))
        .opacity(1 - exit)
        .offset(y: -exit * 10)
    }

    @ViewBuilder
    private func selectedPackage(routeProgress: CGFloat) -> some View {
        if let decision = presentedDecision, routeProgress > 0 {
            let reveal = smoothstep(0.01, 0.12, routeProgress)
            let impact = smoothstep(0.70, 0.84, routeProgress)
            HStack(spacing: 7) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(decision.title.uppercased()) PACKAGE")
                        .font(.system(size: 12, weight: .black))
                    Text("\(presentedTools.count) modules")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.orange.opacity(0.58), lineWidth: 1)
            }
            .shadow(color: .orange.opacity(0.18), radius: 8)
            .scaleEffect(0.82 + reveal * 0.18 - impact * 0.3)
            .opacity(reveal * (1 - impact))
        }
    }

    private func packetLayer(
        size: CGSize,
        progress: CGFloat,
        sourceY: CGFloat,
        targetY: CGFloat
    ) -> some View {
        ZStack {
            ForEach(Array(packetLabels.enumerated()), id: \.offset) { index, label in
                let start = 0.18 + CGFloat(index) * 0.035
                let local = smoothstep(start, min(0.82, start + 0.48), progress)
                let fade = 1 - smoothstep(0.84, 0.94, local)
                ToolPacket(label: label)
                    .position(packetPosition(
                        index: index,
                        progress: local,
                        width: size.width,
                        sourceY: sourceY,
                        targetY: targetY
                    ))
                    .scaleEffect(0.88 + local * 0.08 - smoothstep(0.82, 1, local) * 0.34)
                    .opacity(progress < start ? 0 : fade)
            }
        }
    }

    private func systemPromptCore(routeProgress: CGFloat) -> some View {
        let receiving = routeProgress >= 0.22 && routeProgress < 0.88
        let complete = routeProgress >= 0.88
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.cyan)
                Text("SYSTEM_PROMPT")
                    .font(.system(size: 13, weight: .black))
                    .tracking(1)
                Spacer()
                Text(complete ? "LOCKED" : receiving ? "RECEIVING" : "OPEN")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(complete ? .green : receiving ? .orange : .cyan)
            }

            HStack(spacing: 5) {
                coreSegment("POLICY", tint: .cyan)
                coreSegment("CONTEXT", tint: .purple)
                coreSegment(presentedDecision?.title.uppercased() ?? "ROUTER", tint: complete ? .green : .orange)
            }

            Divider()

            if complete {
                VStack(alignment: .leading, spacing: 9) {
                    if let decision = presentedDecision {
                        Text(decision.summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    installedTools
                        .frame(maxHeight: .infinity, alignment: .top)
                    if let decision = presentedDecision {
                        HStack(spacing: 10) {
                            Label(
                                decision.source == .model ? "AnchorSignal" : "Fallback",
                                systemImage: decision.source == .model
                                    ? "waveform.path.ecg"
                                    : "exclamationmark.triangle"
                            )
                            if decision.source == .model {
                                Text("score \(decision.topScore.formatted(.number.precision(.fractionLength(3))))")
                                Text("margin \(decision.margin.formatted(.number.precision(.fractionLength(3))))")
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle")
                    Text(receiving ? "ACCEPTING ROUTING PAYLOAD…" : "AWAITING PACKAGE")
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(receiving ? .orange : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(
                    complete ? Color.green.opacity(0.5) : receiving ? Color.orange.opacity(0.42) : Color.cyan.opacity(0.22),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(complete ? Color.green : receiving ? Color.orange : Color.cyan)
                .frame(width: complete ? 86 : receiving ? 112 : 58, height: 3)
                .shadow(color: complete ? .green : receiving ? .orange : .cyan, radius: 7)
        }
    }

    private func routingFooter(routeProgress: CGFloat) -> some View {
        HStack(spacing: 7) {
            Image(systemName: routeProgress >= 1 ? "checkmark.seal.fill" : "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(routeProgress >= 1 ? .green : .cyan)
            Text(routeProgress >= 1 ? "SYSTEM PROMPT ASSEMBLED" : "ROUTING PIPELINE ACTIVE")
                .font(.system(size: 10, weight: .black))
                .tracking(0.7)
            Spacer()
            if let decision = presentedDecision {
                Text("\(decision.title) · \(presentedTools.count) tools · \(decision.latencyMilliseconds.formatted(.number.precision(.fractionLength(0)))) ms")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(routeProgress > 0 ? 1 : 0.5)
    }

    private var installedTools: some View {
        Group {
            if presentedTools.isEmpty {
                Text("NO TOOL MODULES · CONVERSATION ROUTE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)],
                    alignment: .leading,
                    spacing: 5
                ) {
                    ForEach(Array(presentedTools.prefix(6)), id: \.self) { name in
                        HStack(spacing: 5) {
                            Circle().fill(.green).frame(width: 4, height: 4)
                            Text(name)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                        }
                    }
                    if presentedTools.count > 6 {
                        Text("+\(presentedTools.count - 6) modules")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func coreSegment(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .black))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(tint.opacity(0.22), lineWidth: 1)
            }
    }

    @MainActor
    private func prepareCurrentRoutingStory() async {
        let prompt = chatStore.dynamicRoutingPromptPreview
        guard !prompt.isEmpty else {
            presentedPrompt = ""
            presentedDecision = nil
            presentedTools = []
            routeStartedAt = nil
            return
        }

        presentedPrompt = prompt
        presentedDecision = nil
        presentedTools = []
        scanStartedAt = .now
        routeStartedAt = nil

        try? await Task.sleep(for: reduceMotion ? .milliseconds(80) : .milliseconds(900))
        guard !Task.isCancelled else { return }
        while chatStore.dynamicRoutingDecision == nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard !Task.isCancelled, let decision = chatStore.dynamicRoutingDecision else { return }

        presentedDecision = decision
        presentedTools = chatStore.dynamicRoutingPresentedToolNames
        routeStartedAt = .now
    }

    private func routeProgress(at date: Date) -> CGFloat {
        guard let routeStartedAt else { return 0 }
        if reduceMotion { return 1 }
        return min(1, max(0, date.timeIntervalSince(routeStartedAt) / 2.35))
    }

    private func scanProgress(at date: Date) -> CGFloat {
        if routeStartedAt != nil { return 1 }
        if reduceMotion { return 1 }
        let cycle = date.timeIntervalSince(scanStartedAt)
            .truncatingRemainder(dividingBy: 1.25) / 1.25
        return cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2
    }

    private func systemPromptHeight(
        in height: CGFloat,
        routeProgress: CGFloat
    ) -> CGFloat {
        let settle = smoothstep(0.86, 1, routeProgress)
        // Once the transient scan has vanished, let the assembled prompt own
        // almost the entire stage. The larger final surface also pulls its
        // top edge upward, removing the dead space above SYSTEM_PROMPT.
        let expanded = min(680, max(420, height * 0.84))
        return 176 + (expanded - 176) * settle
    }

    private func systemPromptY(
        in height: CGFloat,
        coreHeight: CGFloat,
        routeProgress: CGFloat
    ) -> CGFloat {
        let transit = min(height - 132, max(390, height * 0.59))
        let minimum = coreHeight / 2 + 72
        let maximum = height - coreHeight / 2 - 54
        let final = max(minimum, min(maximum, height * 0.52))
        let settle = smoothstep(0.86, 1, routeProgress)
        return transit + (final - transit) * settle
    }

    private func packagePosition(
        progress: CGFloat,
        width: CGFloat,
        sourceY: CGFloat,
        targetY: CGFloat
    ) -> CGPoint {
        let local = smoothstep(0.08, 0.76, progress)
        let eased = local * local * (3 - 2 * local)
        return CGPoint(
            x: width / 2 + sin(local * .pi) * min(34, width * 0.08),
            y: sourceY + (targetY - sourceY) * eased
        )
    }

    private func packetPosition(
        index: Int,
        progress: CGFloat,
        width: CGFloat,
        sourceY: CGFloat,
        targetY: CGFloat
    ) -> CGPoint {
        let columns: [CGFloat] = [-112, -74, -36, 36, 74, 112, 0, 0]
        let startX = width / 2 + columns[index % columns.count]
        let endX = width / 2 + CGFloat((index % 5) - 2) * 15
        let controlX = width / 2 + (index.isMultiple(of: 2) ? -46 : 46)
        let controlY = sourceY + (targetY - sourceY) * 0.48
        let inverse = 1 - progress
        return CGPoint(
            x: inverse * inverse * startX + 2 * inverse * progress * controlX + progress * progress * endX,
            y: inverse * inverse * (sourceY + CGFloat(index % 2) * 18)
                + 2 * inverse * progress * controlY
                + progress * progress * targetY
        )
    }

    private var packetLabels: [String] {
        let visible = Array(presentedTools.prefix(7))
        guard presentedTools.count > visible.count else { return visible }
        return visible + ["+\(presentedTools.count - visible.count)"]
    }

    private func stageCaption(routeProgress: CGFloat) -> String {
        if routeStartedAt == nil { return "scanning semantic intent" }
        if routeProgress < 0.22 { return "capability package selected" }
        if routeProgress < 0.88 { return "injecting tool modules" }
        return "provider context ready"
    }

    private func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let x = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return x * x * (3 - 2 * x)
    }

    private func packageIcon(_ package: DynamicToolPackage) -> String {
        switch package {
        case .conversation: "bubble.left.and.bubble.right.fill"
        case .exploration: "magnifyingglass"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .git: "arrow.triangle.branch"
        case .build: "hammer.fill"
        case .implementation: "wand.and.stars"
        }
    }
}

private struct ToolPacket: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 11, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.orange.opacity(0.48), lineWidth: 1)
        }
        .shadow(color: .orange.opacity(0.14), radius: 5)
    }
}
