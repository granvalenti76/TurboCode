import AppKit
import SwiftUI

// MARK: - Cowork shared folder

/// Composer control for the Mac folder a Cowork session shares read-only with
/// the VM at `/work`. It sits in the composer footer, where Coding names its
/// workspace, so both domains state "where this request works" in one place.
///
/// Sharing is optional, so the empty state is a quiet invitation rather than
/// a status: a session without a folder is normal and must not look like a
/// warning. Only a folder that disappeared is called out.
struct CoworkFolderMenu: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var errorMessage: String?

    var body: some View {
        Menu {
            if let path = sharedPath {
                Button("Change Folder…") { chooseFolder() }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .disabled(!folderExists)
                Divider()
                Button("Stop Sharing") { apply(nil) }
            } else {
                Button("Share a Folder…") { chooseFolder() }
            }
            Divider()
            // The only way deliverables reach the Mac: a reviewed export.
            Button("Review & Export Deliverables…") { chatStore.presentCoworkExport() }
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
        }
        // Borderless and hugging its label, like the neighbouring footer
        // controls; a bordered menu would compete with the export button.
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .disabled(chatStore.busy)
        .help(help)
        .alert(
            "Studio",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: State

    private var sharedPath: String? { chatStore.activeConversation?.coworkFolder }

    private var folderExists: Bool {
        guard let sharedPath else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: sharedPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private var title: String {
        guard let sharedPath else { return "Share a folder" }
        let name = URL(fileURLWithPath: sharedPath).lastPathComponent
        return folderExists ? name : "\(name) (missing)"
    }

    private var symbol: String {
        guard sharedPath != nil else { return "folder.badge.plus" }
        return folderExists ? "folder" : "exclamationmark.triangle"
    }

    private var help: String {
        guard let sharedPath else {
            return "Share a Mac folder with this Studio session. The VM can read it but never change it."
        }
        return folderExists
            ? "\(sharedPath) is shared read-only at /work"
            : "\(sharedPath) no longer exists and is not shared"
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message = "The Studio VM can read this folder but never change it."
        if let sharedPath { panel.directoryURL = URL(fileURLWithPath: sharedPath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        apply(url)
    }

    private func apply(_ folder: URL?) {
        Task {
            do {
                if chatStore.activeConversation == nil {
                    await chatStore.createThread()
                }
                try await chatStore.setCoworkFolder(folder)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
