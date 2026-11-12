import Foundation
import Observation

/// State of the first-launch sheet: welcome → discovery → review.
///
/// The store exists only while `models.json` is missing. It scans as soon as
/// it is created so the discovery step is usually filled by the time the user
/// leaves the welcome page. Nothing is written until `complete()`; closing
/// the sheet earlier leaves the catalog missing and the sheet returns on the
/// next launch.
@MainActor
@Observable
final class FirstLaunchOnboardingStore {
    enum Step: Equatable {
        case welcome
        case discovery
        case review
    }

    enum PortState: Equatable {
        case checking
        case found
        case notRunning
    }

    struct PortRow: Identifiable, Equatable {
        let candidate: LocalModelServerCandidate
        var state: PortState
        var id: Int { candidate.port }
    }

    enum AddressCheck: Equatable {
        case idle
        case checking
        case notFound
        case invalid
    }

    enum ToolCheck: Equatable {
        case idle
        case running
        case finished(ToolCallProbeResult)
    }

    var step: Step = .welcome
    private(set) var ports: [PortRow]
    /// Servers in discovery order; a typed address is appended once found.
    private(set) var servers: [DiscoveredModelServer] = []
    private(set) var isScanning = false
    var selectedServerID: String?

    var manualAddress = ""
    private(set) var addressCheck: AddressCheck = .idle

    var displayName = ""
    var chosenContextWindow = OnboardingModelConfiguration.defaultContextWindow
    private(set) var toolCheck: ToolCheck = .idle
    private(set) var isSaving = false
    private(set) var saveError: String?

    private let discovery: LocalModelServerDiscovery
    private let config: TurboCodeConfig
    private let onComplete: @MainActor ([RemoteModelConfig]) async -> Void
    private let onDismiss: @MainActor () -> Void
    private var scanTask: Task<Void, Never>?
    private var toolTask: Task<Void, Never>?

    init(
        discovery: LocalModelServerDiscovery = LocalModelServerDiscovery(),
        config: TurboCodeConfig = .shared,
        onComplete: @escaping @MainActor ([RemoteModelConfig]) async -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.discovery = discovery
        self.config = config
        self.onComplete = onComplete
        self.onDismiss = onDismiss
        self.ports = LocalModelServerDiscovery.candidates.map {
            PortRow(candidate: $0, state: .checking)
        }
    }

    // MARK: Derived state

    var llamaServers: [DiscoveredModelServer] { servers.filter { $0.kind == .llamaServer } }
    var otherServers: [DiscoveredModelServer] { servers.filter { $0.kind == .openAICompatible } }
    var notRunningPorts: [PortRow] { ports.filter { $0.state == .notRunning } }
    var checkingPorts: [PortRow] { ports.filter { $0.state == .checking } }

    var selectedServer: DiscoveredModelServer? {
        servers.first { $0.id == selectedServerID }
    }

    // MARK: Discovery

    /// Restarts the loopback scan. Servers found from a typed address stay,
    /// because they are not on a scanned port and would otherwise vanish.
    func scan() {
        scanTask?.cancel()
        let manual = servers.filter { server in
            !LocalModelServerDiscovery.candidates.contains { $0.baseURL == server.baseURL }
        }
        servers = manual
        ports = LocalModelServerDiscovery.candidates.map { PortRow(candidate: $0, state: .checking) }
        isScanning = true
        let stream = discovery.scanLocalhost()
        scanTask = Task { [weak self] in
            for await (candidate, server) in stream {
                self?.record(candidate: candidate, server: server)
            }
            self?.finishScan()
        }
    }

    private func record(candidate: LocalModelServerCandidate, server: DiscoveredModelServer?) {
        if let index = ports.firstIndex(where: { $0.id == candidate.port }) {
            ports[index].state = server == nil ? .notRunning : .found
        }
        guard let server else { return }
        add(server)
    }

    private func finishScan() {
        isScanning = false
        // Results arrive in completion order; present them in port order so
        // the list does not reshuffle between launches.
        let order = LocalModelServerDiscovery.candidates.map(\.baseURL)
        servers.sort { (order.firstIndex(of: $0.baseURL) ?? .max) < (order.firstIndex(of: $1.baseURL) ?? .max) }
        preselect()
    }

    private func add(_ server: DiscoveredModelServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        preselect()
    }

    /// Keeps a user's choice; otherwise prefers llama-server because it needs
    /// no manual settings.
    private func preselect() {
        if let selectedServerID, servers.contains(where: { $0.id == selectedServerID }) { return }
        selectedServerID = (llamaServers.first ?? servers.first)?.id
    }

    func checkManualAddress() async {
        guard let base = LocalModelServerDiscovery.normalizedBaseURL(manualAddress) else {
            addressCheck = .invalid
            return
        }
        addressCheck = .checking
        if let server = await discovery.probe(baseURL: base) {
            add(server)
            selectedServerID = server.id
            addressCheck = .idle
            manualAddress = ""
        } else {
            addressCheck = .notFound
        }
    }

    // MARK: Navigation

    func showDiscovery() {
        step = .discovery
    }

    /// Prepares the review for the selected server and starts the tool check
    /// in the background; the user can confirm before it finishes.
    func showReview() {
        guard let server = selectedServer else { return }
        displayName = OnboardingModelConfiguration.displayName(forModelID: server.primaryModelID)
        if server.kind == .openAICompatible {
            chosenContextWindow = OnboardingModelConfiguration.defaultContextWindow
        }
        saveError = nil
        step = .review
        runToolCheck()
    }

    func backToDiscovery() {
        toolTask?.cancel()
        toolCheck = .idle
        step = .discovery
    }

    func runToolCheck() {
        guard let server = selectedServer else { return }
        toolTask?.cancel()
        toolCheck = .running
        let discovery = discovery
        toolTask = Task { [weak self] in
            let result = await discovery.probeToolCalling(server: server, modelID: server.primaryModelID)
            guard !Task.isCancelled else { return }
            self?.toolCheck = .finished(result)
        }
    }

    /// Closes without writing; the sheet returns on the next launch.
    func setUpLater() {
        cancelWork()
        onDismiss()
    }

    func complete() async {
        guard let server = selectedServer, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let model = OnboardingModelConfiguration.localModel(
            server: server,
            modelID: server.primaryModelID,
            displayName: displayName,
            chosenContextWindow: server.kind == .llamaServer ? nil : chosenContextWindow
        )
        do {
            let models = try config.completeModelSetup(localModel: model)
            cancelWork()
            await onComplete(models)
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func cancelWork() {
        scanTask?.cancel()
        toolTask?.cancel()
    }
}
