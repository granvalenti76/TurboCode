import FoundationModels
import FoundationModelsUtilities

/// Immutable provider selection used to bootstrap the first Foundation Models
/// session before workspace instructions and tools are loaded.
///
/// This value carries configuration only. The runtime creates and retains the
/// concrete model, session, and reasoning relay as one private ownership unit.
struct FoundationModelsBootstrapConfiguration {
    let backend: ModelBackend
    let usesSystemModel: Bool
    let remoteModel: RemoteModelConfig
    let reasoningEffort: ReasoningEffort?

    init(
        backend: ModelBackend,
        usesSystemModel: Bool,
        remoteModel: RemoteModelConfig,
        reasoningEffort: ReasoningEffort? = nil
    ) {
        self.backend = backend
        self.usesSystemModel = usesSystemModel
        self.remoteModel = remoteModel
        self.reasoningEffort = reasoningEffort
    }
}

/// Value-only history type exposed at persistence and navigation boundaries.
/// Naming it here keeps observable stores from importing Foundation Models just
/// to describe restoration input.
typealias FoundationModelsTranscriptEntry = Transcript.Entry

/// Capability queries live beside the concrete system model adapter. UI code
/// receives only the resulting Boolean and never touches the provider object.
enum FoundationModelsCapabilities {
    static var onDeviceSupportsToolCalling: Bool {
        SystemLanguageModel.default.capabilities.contains(.toolCalling)
    }
}

/// Owns the concrete Foundation Models session and its transport reasoning relay.
///
/// This type is deliberately not observable. UI-facing stores may project model
/// configuration and transcript snapshots, but provider objects live here so a
/// view update cannot replace or retain an in-flight session accidentally.
actor FoundationModelsSessionRuntime {
    private(set) var session: LanguageModelSession
    private var reasoningStreamRelay: ReasoningStreamRelay
    /// Canonical portable history remains independent from the context view
    /// materialized into the provider session. This is the invariant that
    /// makes exclusions reversible and prevents persistence from silently
    /// replacing the user's full transcript with a compacted projection.
    private var canonicalHistory: [Transcript.Entry] = []
    private var materializedSnapshot: [Transcript.Entry]
    private var contextProjection: TranscriptContextProjection = .empty

    init(
        configuration: FoundationModelsBootstrapConfiguration
    ) {
        let relay = ReasoningStreamRelay()
        reasoningStreamRelay = relay
        let model: any LanguageModel = configuration.usesSystemModel
            ? SystemLanguageModel.default
            : ProviderLanguageModel(
                configuration: configuration.remoteModel,
                credential: configuration.remoteModel.credential,
                reasoningStreamRelay: configuration.backend == .llamaServer
                    ? relay
                    : nil,
                reasoningEffort: configuration.reasoningEffort
            )
        session = LanguageModelSession(model: model)
        materializedSnapshot = Array(session.transcript)
    }

    /// Injection seam retained for focused ownership tests. Production hosts
    /// use the configuration initializer so provider construction stays here.
    init(
        backend: ModelBackend,
        modelBuilder: @Sendable (ReasoningStreamRelay?) -> any LanguageModel
    ) {
        let relay = ReasoningStreamRelay()
        reasoningStreamRelay = relay
        session = LanguageModelSession(
            model: modelBuilder(backend == .llamaServer ? relay : nil)
        )
        materializedSnapshot = Array(session.transcript)
    }

    /// Read-only checkpoint used by persistence and context-retention policy.
    /// Callers receive Foundation Models' value snapshot, never session ownership.
    var transcript: Transcript {
        session.transcript
    }

    /// Synchronizes entries appended by the active provider and returns the
    /// unprojected history used by persistence and transcript inspection.
    func canonicalTranscript() -> Transcript {
        synchronizeCanonicalHistory()
        return Transcript(entries: canonicalHistory)
    }

    var transcriptContextProjection: TranscriptContextProjection {
        contextProjection
    }

    /// Borrows one coherent session generation. Returning the session and its
    /// relay together prevents an adapter from observing a rebuild between two
    /// independent actor reads.
    func resources(
        for backend: ModelBackend
    ) -> (session: LanguageModelSession, reasoningRelay: ReasoningStreamRelay?) {
        (
            session,
            backend == .llamaServer ? reasoningStreamRelay : nil
        )
    }

    /// Builds the next session and relay as one replacement unit.
    ///
    /// The old values remain retained by any admitted adapter until that turn
    /// unwinds. Assigning only after construction prevents configuration changes
    /// from pairing a new session with the previous session's reasoning relay.
    func rebuild(
        configuration: ModelSessionConfiguration,
        canonicalHistory: [Transcript.Entry],
        projection: TranscriptContextProjection,
        events: ModelSessionEvents
    ) {
        let nextRelay = ReasoningStreamRelay()
        let materializedHistory = projection.applying(to: canonicalHistory)
        let nextSession = ModelSessionFactory.makeSession(
            configuration: configuration,
            history: materializedHistory,
            events: events,
            reasoningStreamRelay: configuration.backend == .llamaServer
                ? nextRelay
                : nil
        )
        self.canonicalHistory = canonicalHistory
        contextProjection = projection
        materializedSnapshot = Array(nextSession.transcript)
        reasoningStreamRelay = nextRelay
        session = nextSession
    }

    /// Provider profile modifiers may remove older entries before generation.
    /// The longest leading subsequence still present in the previous materialized
    /// snapshot is old history; everything after it is newly generated history.
    /// This handles both ordinary append-only sessions and automatic tool-call
    /// pruning without reintroducing excluded entries into the provider view.
    private func synchronizeCanonicalHistory() {
        let current = Array(session.transcript)
        let newEntryStart = firstNewEntryIndex(
            previous: materializedSnapshot,
            current: current
        )
        if newEntryStart < current.endIndex {
            canonicalHistory.append(contentsOf: current[newEntryStart...])
        }
        materializedSnapshot = current
    }

    private func firstNewEntryIndex(
        previous: [Transcript.Entry],
        current: [Transcript.Entry]
    ) -> Int {
        guard !previous.isEmpty else { return 0 }
        var previousSearchStart = previous.startIndex
        var currentIndex = current.startIndex

        while currentIndex < current.endIndex,
              let match = previous[previousSearchStart...]
                .firstIndex(of: current[currentIndex]) {
            previousSearchStart = previous.index(after: match)
            current.formIndex(after: &currentIndex)
            if previousSearchStart == previous.endIndex {
                break
            }
        }
        return currentIndex
    }
}
