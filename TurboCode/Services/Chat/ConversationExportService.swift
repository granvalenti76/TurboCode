import AppKit
import Foundation
import UniformTypeIdentifiers

/// AppKit bridge for sidebar exports. The service owns only temporary export
/// files; the caller chooses the final destination through a native save panel.
enum ConversationExportService {
    enum ExportError: LocalizedError {
        case noSavedConversations
        case archiveFailed
        case notesUnavailable

        var errorDescription: String? {
            switch self {
            case .noSavedConversations:
                "There are no saved transcripts to export."
            case .archiveFailed:
                "The transcripts could not be packaged into a ZIP archive."
            case .notesUnavailable:
                "Notes is not available as a sharing destination."
            }
        }
    }

    @MainActor
    final class SharePresenter: NSObject, NSSharingServicePickerDelegate {
        private var picker: NSSharingServicePicker?
        private var services: [NSSharingService] = []
        private var failureHandler: ((String) -> Void)?

        func present(
            _ items: [ConversationExportItem],
            suggestedName: String,
            failureHandler: @escaping (String) -> Void
        ) {
            guard !items.isEmpty else {
                failureHandler(ExportError.noSavedConversations.localizedDescription)
                return
            }

            self.failureHandler = failureHandler
            if items.count == 1, let item = items.first {
                services = [notesService(), saveService(for: item)].compactMap { $0 }
            } else {
                services = [saveArchiveService(for: items, suggestedName: suggestedName)]
            }

            guard !services.isEmpty,
                  let anchorView = NSApp.keyWindow?.contentView else {
                failureHandler(ExportError.notesUnavailable.localizedDescription)
                return
            }

            let shareItems: [Any] = items.compactMap { item in
                guard let text = String(data: item.data, encoding: .utf8) else {
                    return nil
                }
                return NSPreviewRepresentingActivityItem(
                    item: text,
                    title: item.title,
                    image: nil,
                    icon: NSImage(
                        systemSymbolName: "text.document",
                        accessibilityDescription: "Transcript"
                    )
                )
            }
            picker = NSSharingServicePicker(items: shareItems)
            picker?.delegate = self

            let windowPoint = anchorView.window?.mouseLocationOutsideOfEventStream
                ?? NSPoint(x: anchorView.bounds.midX, y: anchorView.bounds.midY)
            let anchorPoint = anchorView.convert(windowPoint, from: nil)
            let anchorRect = NSRect(origin: anchorPoint, size: NSSize(width: 1, height: 1))
            picker?.show(
                relativeTo: anchorRect,
                of: anchorView,
                preferredEdge: .minY
            )
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            sharingServicesForItems items: [Any],
            proposedSharingServices proposedServices: [NSSharingService]
        ) -> [NSSharingService] {
            // The picker is deliberately allowlisted: the sidebar promises
            // only Notes and file export, not every installed share extension.
            services
        }

        private func notesService() -> NSSharingService? {
            NSSharingService(
                named: NSSharingService.Name("com.apple.Notes.SharingExtension")
            )
        }

        private func saveService(for item: ConversationExportItem) -> NSSharingService {
            NSSharingService(
                title: "Save JSON File…",
                image: NSImage(
                    systemSymbolName: "square.and.arrow.down",
                    accessibilityDescription: "Save JSON File"
                ) ?? NSImage(),
                alternateImage: nil
            ) { [weak self] in
                do {
                    try ConversationExportService.saveJSON(item)
                } catch {
                    self?.failureHandler?(error.localizedDescription)
                }
            }
        }

        private func saveArchiveService(
            for items: [ConversationExportItem],
            suggestedName: String
        ) -> NSSharingService {
            return NSSharingService(
                title: "Save ZIP File…",
                image: NSImage(
                    systemSymbolName: "archivebox",
                    accessibilityDescription: "Save ZIP File"
                ) ?? NSImage(),
                alternateImage: nil
            ) { [weak self] in
                do {
                    try ConversationExportService.saveZIP(
                        items,
                        suggestedName: suggestedName
                    )
                } catch {
                    self?.failureHandler?(error.localizedDescription)
                }
            }
        }
    }

    static func saveJSON(_ item: ConversationExportItem) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = item.suggestedFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try item.data.write(to: url, options: .atomic)
    }

    static func saveZIP(
        _ items: [ConversationExportItem],
        suggestedName: String
    ) throws {
        guard !items.isEmpty else { throw ExportError.noSavedConversations }

        let fileManager = FileManager.default
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("turbocode-export-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(safeName(suggestedName))-transcripts-\(UUID().uuidString).zip")
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
            try? fileManager.removeItem(at: archiveURL)
        }

        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        for (index, item) in items.enumerated() {
            let indexedName = String(format: "%02d", index + 1)
                + "-"
                + item.suggestedFileName
            try item.data.write(
                to: stagingDirectory.appendingPathComponent(indexedName),
                options: .atomic
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--sequesterRsrc",
            stagingDirectory.path,
            archiveURL.path
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.archiveFailed
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(safeName(suggestedName))-transcripts.zip"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        try fileManager.copyItem(at: archiveURL, to: destinationURL)
    }

    private static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let sanitized = value.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "TurboCode" : sanitized
    }
}
