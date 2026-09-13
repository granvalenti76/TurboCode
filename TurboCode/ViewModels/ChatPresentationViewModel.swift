import Observation

/// Presentation-only state for chat chrome and transient runtime feedback.
///
/// Provider ownership, turn reduction, transcript mutation, and persistence do
/// not belong here. Keeping these cheap UI values behind their own Observation
/// boundary prevents streamed timeline updates from invalidating unrelated
/// banners and composer metadata.
@MainActor
@Observable
final class ChatPresentationViewModel {
    var runtimeStatus: RuntimeStatus = .ready
    var errorMessage: String?
    /// Profile handoff is UI-visible transition state, not provider ownership.
    /// The selection coordinator publishes it so composer observation remains
    /// correct after task lifetime moves out of the compatibility facade.
    private(set) var isProfileTransitioning = false
    private(set) var localCompactionNotice: LocalCompactionNotice?
    private(set) var llamaContextUsage: LlamaContextUsage?
    /// Lightweight UI projection; reduction and persistence live in the
    /// ComposerSessionStatisticsStore.
    private(set) var composerSessionStatistics: ComposerSessionStatistics?

    private var compactionNoticeTask: Task<Void, Never>?

    func setLlamaContextUsage(_ usage: LlamaContextUsage?) {
        llamaContextUsage = usage
    }

    func setComposerSessionStatistics(
        _ statistics: ComposerSessionStatistics?
    ) {
        composerSessionStatistics = statistics
        llamaContextUsage = statistics.flatMap { value in
            guard let context = value.context else { return nil }
            return LlamaContextUsage(
                usedTokens: context.usedTokens,
                contextSize: context.contextSize
            )
        }
    }

    func setProfileTransitioning(_ value: Bool) {
        isProfileTransitioning = value
    }

    /// Replaces any older notice and owns its cancellable presentation lifetime.
    /// Chat orchestration publishes the value once; it never manages a UI timer.
    func presentCompactionNotice(_ notice: LocalCompactionNotice) {
        compactionNoticeTask?.cancel()
        localCompactionNotice = notice
        compactionNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled else { return }
            self?.clearCompactionNotice()
        }
    }

    func clearCompactionNotice() {
        compactionNoticeTask?.cancel()
        compactionNoticeTask = nil
        localCompactionNotice = nil
    }
}

/// MainActor binding between the active conversation and the pure statistics
/// reducer. It publishes only the current immutable snapshot to the view.
@MainActor
final class ComposerSessionStatisticsStore {
    private weak var presentation: ChatPresentationViewModel?
    private var reducers: [String: ComposerSessionStatisticsReducer] = [:]
    private(set) var activeConversationID: String?

    init(presentation: ChatPresentationViewModel) {
        self.presentation = presentation
    }

    var activeStatistics: ComposerSessionStatistics? {
        guard let activeConversationID else { return nil }
        return reducers[activeConversationID]?.statistics
    }

    func activate(
        conversationID: String,
        restored: ComposerSessionStatistics? = nil
    ) {
        activeConversationID = conversationID
        if let restored, restored.conversationID == conversationID {
            reducers[conversationID] = ComposerSessionStatisticsReducer(
                statistics: restored
            )
        } else if reducers[conversationID] == nil {
            reducers[conversationID] = ComposerSessionStatisticsReducer(
                conversationID: conversationID
            )
        }
        publish()
    }

    func remove(conversationID: String) {
        reducers.removeValue(forKey: conversationID)
        if activeConversationID == conversationID {
            activeConversationID = nil
            presentation?.setComposerSessionStatistics(nil)
        }
    }

    func record(
        requestID: String,
        backend: String,
        usage: Usage,
        context: ContextUsage? = nil
    ) {
        guard let activeConversationID else { return }
        var reducer = reducers[activeConversationID]
            ?? ComposerSessionStatisticsReducer(conversationID: activeConversationID)
        reducer.apply(
            ComposerUsageSample(
                requestID: requestID,
                backend: backend,
                inputTokens: usage.inputTokens,
                cachedInputTokens: usage.cachedInputTokens,
                outputTokens: usage.outputTokens
            ),
            context: context,
            contextBackend: backend
        )
        reducers[activeConversationID] = reducer
        publish()
    }

    func invalidateContext() {
        guard let activeConversationID,
              var reducer = reducers[activeConversationID] else { return }
        reducer.invalidateContext()
        reducers[activeConversationID] = reducer
        publish()
    }

    private func publish() {
        presentation?.setComposerSessionStatistics(activeStatistics)
    }
}
