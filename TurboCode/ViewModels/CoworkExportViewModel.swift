import AppKit
import Foundation
import Observation

/// State of one Cowork export review: the plan, the user's per-file decisions,
/// and the export result. Planning and copying run off the main actor.
@MainActor
@Observable
final class CoworkExportViewModel {
    enum Phase: Equatable {
        case idle
        case planning
        case ready
        case exporting
        case finished(CoworkExportReport)
        case failed(String)
    }

    let presentation: CoworkExportPresentation
    private(set) var destination: URL?
    private(set) var plan: CoworkExportPlan?
    private(set) var phase: Phase = .idle
    var decisions: [String: CoworkExportDecision] = [:]
    /// Required before exporting more than `CoworkExportPlan` limits allow.
    var confirmsLargeExport = false

    private let service = CoworkExportService()

    init(presentation: CoworkExportPresentation) {
        self.presentation = presentation
        destination = presentation.defaultDestination
    }

    var selectedItems: [CoworkExportItem] {
        plan?.items.filter { (decisions[$0.id] ?? .skip) != .skip } ?? []
    }

    var canExport: Bool {
        guard phase == .ready, destination != nil, !selectedItems.isEmpty, let plan else { return false }
        return !plan.exceedsLimits || confirmsLargeExport
    }

    // MARK: Planning

    func refresh() async {
        guard let destination else {
            plan = nil
            phase = .ready
            return
        }
        phase = .planning
        let outbox = presentation.outbox
        do {
            let plan = try await Task.detached(priority: .userInitiated) {
                try CoworkExportPlanner.plan(outbox: outbox, destination: destination)
            }.value
            self.plan = plan
            decisions = Dictionary(uniqueKeysWithValues: plan.items.map {
                ($0.id, CoworkExportDecision.default(for: $0))
            })
            confirmsLargeExport = false
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func chooseDestination() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where the Cowork deliverables are copied on this Mac."
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
        await refresh()
    }

    // MARK: Export

    func export() async {
        guard canExport, let plan else { return }
        phase = .exporting
        let decisions = decisions
        let report = await service.export(plan: plan, decisions: decisions)
        phase = .finished(report)
    }

    /// A display-only diff between the Mac file and the incoming file.
    func diffBlock(for item: CoworkExportItem) -> DiffPatchBlock? {
        guard item.isText,
              let incoming = try? Data(contentsOf: item.source),
              let incomingText = UnifiedTextDiff.reviewableText(incoming) else { return nil }
        let existingText = (try? Data(contentsOf: item.destination)).flatMap(UnifiedTextDiff.reviewableText)
        return UnifiedTextDiff.reviewBlock(
            path: item.relativePath,
            original: existingText,
            modified: incomingText,
            root: destination?.path ?? "",
            location: .coworkVM
        )
    }

    // MARK: Outbox

    func showOutboxInFinder() {
        try? FileManager.default.createDirectory(at: presentation.outbox, withIntermediateDirectories: true)
        NSWorkspace.shared.open(presentation.outbox)
    }

    /// Deletes this session's deliverables on the Mac. The VM sees an empty
    /// /out afterwards; nothing else is touched.
    func clearDeliverables() async {
        let outbox = presentation.outbox
        let contents = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
        await refresh()
    }
}
