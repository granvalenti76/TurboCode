import SwiftUI

/// Settings → Providers section that points the local model at a running
/// server without editing `models.json`.
///
/// The user names the kind of server and its address; everything else is
/// read from the server: the loaded model's identifier (often a long Hugging
/// Face path nobody should type), image support, and, for llama-server only,
/// the context window. Detection preselects the kind, but the user's choice
/// wins, because the same port often runs different servers on different
/// days. Nothing is written until Apply.
struct LocalServerSettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore

    @State private var kind: LocalModelServerKind = .llamaServer
    @State private var address = ""
    @State private var modelID = ""
    @State private var contextWindow = OnboardingModelConfiguration.defaultContextWindow
    @State private var detection: Detection = .idle
    @State private var saveError: String?
    @State private var didLoad = false

    /// The probe's outcome for the address currently in the field.
    private enum Detection: Equatable {
        case idle
        case checking
        case found(DiscoveredModelServer)
        case unreachable
    }

    var body: some View {
        Section {
            Picker("Server", selection: $kind) {
                Text("llama-server").tag(LocalModelServerKind.llamaServer)
                Text("MLX VLM").tag(LocalModelServerKind.mlxVLM)
                Text("Other OpenAI-compatible").tag(LocalModelServerKind.openAICompatible)
            }

            TextField("Address", text: $address, prompt: Text("http://127.0.0.1:8080/v1"))
                .textContentType(.URL)
                .autocorrectionDisabled()
                .onSubmit { detect() }

            LabeledContent("Status") { statusView }

            modelRow

            LabeledContent("Images") {
                Text(imagesDescription).foregroundStyle(.secondary)
            }

            Picker("Context window", selection: $contextWindow) {
                ForEach(contextChoices, id: \.self) { tokens in
                    Text(Self.contextLabel(tokens)).tag(tokens)
                }
            }

            if let kindMismatch {
                Label(kindMismatch, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Check Again") { detect() }
                    .disabled(detection == .checking)
                Button("Apply") { apply() }
                    .disabled(!canApply)
            }
        } header: {
            Text("Local Server")
        } footer: {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            // Loading fills the address, which starts the first detection
            // through the address task below.
            loadCurrentEntry()
        }
        .task(id: address) {
            // Typing changes the address on every keystroke; wait for a pause
            // so a half-typed port is not probed and reported as unreachable.
            guard didLoad, !address.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            detect()
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var statusView: some View {
        switch detection {
        case .idle:
            Text("Not checked").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .found(let server):
            Label("Connected to \(server.product)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unreachable:
            Label("No server at this address", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        let ids = detectedModelIDs
        if ids.count > 1 {
            Picker("Model", selection: $modelID) {
                ForEach(ids, id: \.self) { id in
                    Text(id).tag(id)
                }
            }
        } else {
            LabeledContent("Model") {
                Text(modelID.isEmpty ? "Detected from the server" : modelID)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Derived state

    private var detectedServer: DiscoveredModelServer? {
        if case .found(let server) = detection { return server }
        return nil
    }

    private var detectedModelIDs: [String] {
        detectedServer?.modelIDs ?? []
    }

    /// The fixed choices plus whatever is stored or reported, so a value set
    /// by hand or by llama-server is shown instead of silently replaced.
    private var contextChoices: [Int] {
        var choices = OnboardingModelConfiguration.contextWindowChoices
        for value in [contextWindow, detectedServer?.contextWindowTokens].compactMap(\.self)
        where !choices.contains(value) && value > 0 {
            choices.append(value)
        }
        return choices.sorted()
    }

    private var imagesDescription: String {
        switch kind {
        case .llamaServer:
            guard let vision = detectedServer?.supportsVision else { return "Asked to the server" }
            return vision ? "Supported" : "Not supported by the loaded model"
        case .mlxVLM:
            return "Supported"
        case .openAICompatible:
            return "Off"
        }
    }

    /// Shown when the server answers as a different kind than the one picked.
    private var kindMismatch: String? {
        guard let server = detectedServer, server.kind != kind else { return nil }
        return "This address answers as \(server.product)."
    }

    private var footerText: String {
        switch kind {
        case .llamaServer:
            "TurboCode reads the context window and image support from llama-server each time it starts."
        case .mlxVLM:
            "The context window is not read from MLX: the server reports the model's maximum, not what fits in memory. Start at 32K and raise it only if memory allows."
        case .openAICompatible:
            "This server can't report its context window or image support, so they are set here."
        }
    }

    private var canApply: Bool {
        LocalModelServerDiscovery.normalizedBaseURL(address) != nil
            && !modelID.isEmpty
            && detection != .checking
    }

    // MARK: Actions

    /// Fills the form from the stored local entry, so opening Settings shows
    /// what is in use rather than defaults.
    private func loadCurrentEntry() {
        guard !didLoad else { return }
        if let entry = settings.remoteModels.first(where: {
            $0.id == OnboardingModelConfiguration.localModelID
        }) {
            address = entry.url
            modelID = entry.modelName
            contextWindow = entry.contextWindowTokens
            // A stored `true` without `/props` can only have come from MLX;
            // detection corrects this a moment later anyway.
            kind = switch entry.supportsVision {
            case nil: .llamaServer
            case true?: .mlxVLM
            case false?: .openAICompatible
            }
        } else {
            address = "http://127.0.0.1:8080/v1"
        }
        didLoad = true
    }

    private func detect() {
        guard let base = LocalModelServerDiscovery.normalizedBaseURL(address) else {
            detection = .idle
            return
        }
        detection = .checking
        Task {
            let server = await LocalModelServerDiscovery().probe(baseURL: base)
            // The address may have changed while the probe was in flight.
            guard LocalModelServerDiscovery.normalizedBaseURL(address) == base else { return }
            guard let server else {
                detection = .unreachable
                return
            }
            detection = .found(server)
            kind = server.kind
            if !server.modelIDs.contains(modelID) {
                modelID = server.primaryModelID
            }
            if server.kind == .llamaServer, let reported = server.contextWindowTokens {
                contextWindow = reported
            }
        }
    }

    private func apply() {
        guard let base = LocalModelServerDiscovery.normalizedBaseURL(address) else { return }
        do {
            try settings.updateLocalServer(
                baseURL: base,
                kind: kind,
                modelID: modelID,
                contextWindow: contextWindow
            )
            saveError = nil
            address = base
            Task { await chatStore.reloadRemoteModels() }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static func contextLabel(_ tokens: Int) -> String {
        tokens % 1_024 == 0 ? "\(tokens / 1_024)K tokens" : "\(tokens) tokens"
    }
}
