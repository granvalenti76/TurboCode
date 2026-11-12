import AppKit
import SwiftUI

/// First-launch sheet shown while `models.json` is missing.
///
/// One fixed width for every step keeps the sheet from jumping as the user
/// moves through it. The serif is limited to the step titles, following
/// `AppTypography`'s rule that New York sets tone and never shows data.
struct FirstLaunchOnboardingSheet: View {
    @Bindable var store: FirstLaunchOnboardingStore

    var body: some View {
        Group {
            switch store.step {
            case .welcome: OnboardingWelcomeStep(store: store)
            case .discovery: OnboardingDiscoveryStep(store: store)
            case .review: OnboardingReviewStep(store: store)
            }
        }
        .frame(width: 720)
        // The catalog is written only by an explicit choice: Escape and
        // clicks outside must not dismiss half-way.
        .interactiveDismissDisabled()
    }
}

// MARK: - Shared pieces

private struct OnboardingStepHeader: View {
    let step: Int
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step \(step) of 2")
                .font(AppTypography.sectionLabel)
                .textCase(.uppercase)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 26, weight: .medium, design: .serif))
            if let subtitle {
                Text(subtitle)
                    .font(AppTypography.control)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingChip: View {
    let text: String
    var positive = false

    var body: some View {
        Text(text)
            .font(AppTypography.badge)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(positive ? Color.green.opacity(0.14) : Color.primary.opacity(0.06))
            )
            .foregroundStyle(positive ? Color.green : Color.secondary)
    }
}

private extension Int {
    /// 32768 → "32K", 131072 → "128K".
    var contextLabel: String { "\(self / 1_024)K" }
}

// MARK: - Welcome (A1·b)

private struct OnboardingWelcomeStep: View {
    let store: FirstLaunchOnboardingStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                Text("Welcome to TurboCode.")
                    .font(.system(size: 40, weight: .medium, design: .serif))
                Text("An agent for your Mac that runs on a model you host — and asks before it touches your files.")
                    .font(.system(size: 18, design: .serif))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 44)
            .padding(.top, 40)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.05))

            Divider()

            HStack(alignment: .top, spacing: 0) {
                pillar(
                    symbol: "desktopcomputer",
                    title: "Your model, your Mac",
                    text: "Runs on llama-server or any local endpoint. A cloud model is optional."
                )
                Divider()
                pillar(
                    symbol: "checkmark.shield",
                    title: "Every change reviewable",
                    text: "Edits arrive as diffs. Git, shell and deletions wait for your approval."
                )
                Divider()
                pillar(
                    symbol: "shippingbox",
                    title: "Coding and Studio",
                    text: "Write code in your project, or make pages, data and documents in a sandboxed VM."
                )
            }
            .padding(.vertical, 26)
            .padding(.horizontal, 24)

            Divider()

            HStack(spacing: 10) {
                Text("Setup takes about a minute. First, let’s find your model.")
                    .font(AppTypography.control)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Set Up Later") { store.setUpLater() }
                Button("Get Started") { store.showDiscovery() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }

    private func pillar(symbol: String, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title).font(AppTypography.controlEmphasized)
            Text(text)
                .font(AppTypography.control)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }
}

// MARK: - Discovery (A2·b)

private struct OnboardingDiscoveryStep: View {
    @Bindable var store: FirstLaunchOnboardingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingStepHeader(step: 1, title: title, subtitle: subtitle)

            if !store.llamaServers.isEmpty {
                section(
                    "Recommended · configured automatically",
                    servers: store.llamaServers
                )
            }
            if !store.otherServers.isEmpty {
                section("Other OpenAI-compatible", servers: store.otherServers)
            }
            statusLine
            addressRow

            Divider()
            HStack(spacing: 10) {
                Button("Scan Again") { store.scan() }
                    .disabled(store.isScanning)
                Button("Set Up Later") { store.setUpLater() }
                Spacer()
                Button("Back") { store.step = .welcome }
                Button("Continue") { store.showReview() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.selectedServer == nil)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    private var title: String {
        if !store.servers.isEmpty {
            return store.servers.count == 1
                ? "We found a model server"
                : "We found \(store.servers.count) model servers"
        }
        return store.isScanning ? "Looking for model servers…" : "No model server is running"
    }

    private var subtitle: String? {
        guard store.servers.isEmpty, !store.isScanning else { return nil }
        return "Start your server and scan again, or enter its address below."
    }

    private func section(_ title: String, servers: [DiscoveredModelServer]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppTypography.sectionLabel)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { Divider() }
                    serverRow(server)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
    }

    private func serverRow(_ server: DiscoveredModelServer) -> some View {
        let selected = store.selectedServerID == server.id
        return Button {
            store.selectedServerID = server.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(OnboardingModelConfiguration.displayName(forModelID: server.primaryModelID))
                        .font(AppTypography.controlEmphasized)
                    Text("\(server.product) · \(hostAndPort(server.baseURL))")
                        .font(AppTypography.code)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if server.kind == .llamaServer {
                    if let context = server.contextWindowTokens {
                        OnboardingChip(text: "\(context.contextLabel) context · auto", positive: true)
                    }
                } else {
                    OnboardingChip(text: "Context: you choose")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.07) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var statusLine: some View {
        let notRunning = store.notRunningPorts
        HStack(spacing: 6) {
            if store.isScanning {
                ProgressView().controlSize(.small)
                Text("Checking \(store.checkingPorts.map { ":\($0.id)" }.joined(separator: " · "))")
            } else if !notRunning.isEmpty {
                Text("Not running · " + notRunning.map { "\($0.candidate.product) :\($0.id)" }.joined(separator: " · "))
            }
        }
        .font(AppTypography.metadata)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var addressRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Another machine")
                    .font(AppTypography.controlEmphasized)
                TextField("http://192.168.1.120:8080", text: $store.manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.code)
                    .onSubmit { Task { await store.checkManualAddress() } }
                Button("Check") { Task { await store.checkManualAddress() } }
                    .disabled(store.manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
                              || store.addressCheck == .checking)
            }
            switch store.addressCheck {
            case .checking:
                Text("Checking…").font(AppTypography.metadata).foregroundStyle(.secondary)
            case .notFound:
                Text("No OpenAI-compatible server answered at that address.")
                    .font(AppTypography.metadata).foregroundStyle(.red)
            case .invalid:
                Text("Enter an http or https address with a host.")
                    .font(AppTypography.metadata).foregroundStyle(.red)
            case .idle:
                EmptyView()
            }
        }
    }

    private func hostAndPort(_ baseURL: String) -> String {
        guard let url = URL(string: baseURL), let host = url.host() else { return baseURL }
        let shownHost = host == "127.0.0.1" ? "localhost" : host
        return url.port.map { "\(shownHost):\($0)" } ?? shownHost
    }
}

// MARK: - Review (A3·b / A3·c / A3·d)

private struct OnboardingReviewStep: View {
    @Bindable var store: FirstLaunchOnboardingStore

    var body: some View {
        if let server = store.selectedServer {
            content(server)
        }
    }

    private func content(_ server: DiscoveredModelServer) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingStepHeader(
                step: 2,
                title: title(server),
                subtitle: "\(server.product) · \(server.baseURL)"
            )

            VStack(alignment: .leading, spacing: 5) {
                Text("Name in the composer").font(AppTypography.controlEmphasized)
                TextField("Model name", text: $store.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            if server.kind == .openAICompatible {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Context window").font(AppTypography.controlEmphasized)
                    Picker("Context window", selection: $store.chosenContextWindow) {
                        ForEach(OnboardingModelConfiguration.contextWindowChoices, id: \.self) {
                            Text($0.contextLabel).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Use the value your server loaded the model with.")
                        .font(AppTypography.metadata)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    if server.kind == .llamaServer {
                        tile("Context window",
                             value: server.contextWindowTokens.map { $0.formatted() } ?? "—",
                             note: "Read from llama-server")
                    }
                    toolTile(server)
                    tile("Vision",
                         value: server.supportsVision == true ? "On" : "Off",
                         note: server.kind == .llamaServer ? "Follows the loaded model" : "Not reported by this server")
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Creates ~/.turbocode/models.json. Everything stays editable in Settings.")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
            }

            if let error = store.saveError {
                Text(error).font(AppTypography.metadata).foregroundStyle(.red)
            }

            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Back") { store.backToDiscovery() }
                Button("Create and Start") { Task { await store.complete() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.isSaving)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    private func title(_ server: DiscoveredModelServer) -> String {
        if case .finished(let result) = store.toolCheck, result != .passed {
            return "Tool calls did not respond"
        }
        return server.kind == .llamaServer ? "Nothing to configure" : "One setting we can’t read"
    }

    private func tile(_ label: String, value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(AppTypography.metadata).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold))
            Text(note).font(AppTypography.metadata).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    /// The probe result is reported, never enforced: the user knows their
    /// server, so a failed check does not block creating the configuration.
    @ViewBuilder
    private func toolTile(_ server: DiscoveredModelServer) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Tool calls").font(AppTypography.metadata).foregroundStyle(.secondary)
            switch store.toolCheck {
            case .idle, .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Testing…").font(.system(size: 17, weight: .semibold))
                }
                Text("Asking the model to call a test tool").font(AppTypography.metadata).foregroundStyle(.secondary)
            case .finished(.passed):
                Text(server.kind == .llamaServer ? "Live" : "Working")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Test call succeeded").font(AppTypography.metadata).foregroundStyle(.secondary)
            case .finished(let result):
                Text(result == .unreachable ? "No answer" : "Not called")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.red)
                Button("Test Again") { store.runToolCheck() }
                    .buttonStyle(.link)
                    .font(AppTypography.metadata)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}
