import AppKit
import SwiftUI

// MARK: - Cowork shared folder

/// Toolbar control for the Mac folder a Cowork session shares read-only with
/// the VM at `/work`. It replaces the Mac-workspace controls while a Cowork
/// session is open, because Cowork never works in the Mac workspace.
struct CoworkFolderToolbarMenu: View {
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
        .disabled(chatStore.busy)
        .help(help)
        .alert(
            "Cowork",
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
        guard let sharedPath else { return "No Shared Folder" }
        let name = URL(fileURLWithPath: sharedPath).lastPathComponent
        return folderExists ? name : "\(name) (missing)"
    }

    private var symbol: String {
        guard sharedPath != nil else { return "folder.badge.plus" }
        return folderExists ? "folder.fill" : "exclamationmark.triangle"
    }

    private var help: String {
        guard let sharedPath else {
            return "Share a Mac folder with this Cowork session. The VM can read it but never change it."
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
        panel.message = "The Cowork VM can read this folder but never change it."
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
