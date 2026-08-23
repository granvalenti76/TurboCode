import Foundation
import Observation

nonisolated enum ToolApprovalPresentationEvent: Sendable {
    case present(ApprovalRequest)
    case dismiss(String)
}

/// Bridges host-owned approval requests to the native UI without routing
/// execution state through the chat façade or through model-authored text.
actor ToolApprovalPresentationBroker {
    static let shared = ToolApprovalPresentationBroker()

    private var observers: [UUID: AsyncStream<ToolApprovalPresentationEvent>.Continuation] = [:]

    func events() -> AsyncStream<ToolApprovalPresentationEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeObserver(id) }
            }
        }
    }

    func publish(_ event: ToolApprovalPresentationEvent) {
        for observer in observers.values {
            observer.yield(event)
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }
}

/// Owns only approval presentation and decisions. The registered tool action
/// remains actor-owned by ToolApprovalRegistry and is executed at most once.
@MainActor
@Observable
final class ApprovalStore {
    private(set) var pendingApproval: ApprovalRequest?

    private var queuedApprovals: [ApprovalRequest] = []
    private var observationTask: Task<Void, Never>?

    func start() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            let events = await ToolApprovalPresentationBroker.shared.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }
    }

    func approve() {
        guard let request = takePendingApproval() else { return }
        Task { _ = await ToolApprovalRegistry.shared.approve(id: request.id) }
    }

    func reject() {
        guard let request = takePendingApproval() else { return }
        Task { _ = await ToolApprovalRegistry.shared.reject(id: request.id) }
    }

    private func receive(_ event: ToolApprovalPresentationEvent) {
        switch event {
        case .present(let request):
            guard pendingApproval?.id != request.id,
                  !queuedApprovals.contains(where: { $0.id == request.id }) else { return }
            if pendingApproval == nil {
                pendingApproval = request
            } else {
                queuedApprovals.append(request)
            }
        case .dismiss(let id):
            if pendingApproval?.id == id {
                advanceQueue()
            } else {
                queuedApprovals.removeAll { $0.id == id }
            }
        }
    }

    private func takePendingApproval() -> ApprovalRequest? {
        guard let request = pendingApproval else { return nil }
        advanceQueue()
        return request
    }

    private func advanceQueue() {
        pendingApproval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst()
    }
}
