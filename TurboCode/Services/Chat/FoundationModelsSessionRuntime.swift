import FoundationModels
import FoundationModelsUtilities

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
        backend: ModelBackend,
        history: [Transcript.Entry],
        events: ModelSessionEvents,
        configurationBuilder: (ReasoningStreamRelay?) -> ModelSessionConfiguration
    ) {
        let nextRelay = ReasoningStreamRelay()
        let nextSession = ModelSessionFactory.makeSession(
            configuration: configurationBuilder(
                backend == .llamaServer ? nextRelay : nil
            ),
            history: history,
            events: events
        )
        reasoningStreamRelay = nextRelay
        session = nextSession
    }
}
