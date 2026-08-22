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
    private(set) var localCompactionNotice: LocalCompactionNotice?
    private(set) var llamaContextUsage: LlamaContextUsage?

    private var compactionNoticeTask: Task<Void, Never>?

    func setLlamaContextUsage(_ usage: LlamaContextUsage?) {
        llamaContextUsage = usage
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
