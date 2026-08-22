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
}

/// Owns the concrete Foundation Models session and its transport reasoning relay.
///
/// This type is deliberately not observable. UI-facing stores may project model
/// configuration and transcript snapshots, but provider objects live here so a
/// view update cannot replace or retain an in-flight session accidentally.
@MainActor
final class FoundationModelsSessionRuntime {
    private(set) var session: LanguageModelSession
    private var reasoningStreamRelay: ReasoningStreamRelay

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
                    : nil
            )
        session = LanguageModelSession(model: model)
    }

    /// Injection seam retained for focused ownership tests. Production hosts
    /// use the configuration initializer so provider construction stays here.
    init(
        backend: ModelBackend,
        modelBuilder: (ReasoningStreamRelay?) -> any LanguageModel
    ) {
        let relay = ReasoningStreamRelay()
        reasoningStreamRelay = relay
        session = LanguageModelSession(
            model: modelBuilder(backend == .llamaServer ? relay : nil)
        )
    }

    /// Read-only checkpoint used by persistence and context-retention policy.
    /// Callers receive Foundation Models' value snapshot, never session ownership.
    var transcript: Transcript {
        session.transcript
    }

    /// Exposes the active session-scoped relay only to the provider adapter.
    /// Other backends must not install a sink on Llama's transport channel.
    func activeReasoningStreamRelay(
        for backend: ModelBackend
    ) -> ReasoningStreamRelay? {
        backend == .llamaServer ? reasoningStreamRelay : nil
    }

    /// Builds the next session and relay as one replacement unit.
    ///
    /// The old values remain retained by any admitted adapter until that turn
    /// unwinds. Assigning only after construction prevents configuration changes
    /// from pairing a new session with the previous session's reasoning relay.
    func rebuild(
        configuration: ModelSessionConfiguration,
        history: [Transcript.Entry],
        events: ModelSessionEvents
    ) {
        let nextRelay = ReasoningStreamRelay()
        let nextSession = ModelSessionFactory.makeSession(
            configuration: configuration,
            history: history,
            events: events,
            reasoningStreamRelay: configuration.backend == .llamaServer
                ? nextRelay
                : nil
        )
        reasoningStreamRelay = nextRelay
        session = nextSession
    }
}
