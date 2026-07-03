import Foundation
import Observation
import SwiftUI
import FoundationModels
import LlamaModelExecutor

// MARK: - Central ChatStore

@MainActor
@Observable
public final class ChatStore {
    // Threads
    public var threads: [Thread] = []
    public var activeThreadId: String?
    public var threadSearch: String = ""
    public var showArchivedThreads: Bool = false

    // Timeline
    public var blocks: [ChatBlock] = []
    public var liveReasoning: String = ""
    public var liveAssistant: String = ""

    // Composer
    public var composerModel: String = "auto"
    public var composerProviderId: String = ""
    public var composerMode: ThreadMode = .agent
    public var composerInput: String = ""
    public var composerAttachments: Int = 0

    // Runtime
    public var runtimeStatus: RuntimeStatus = .ready
    public var runtimeConnection: RuntimeConnectionState = .ready
    public var busy: Bool = false
    public var error: String?

    // Navigation
    public var route: AppRoute = .chat
    public var settingsSection: SettingsSection = .general

    // Sidebar
    public var leftSidebarCollapsed: Bool = false
    public var leftSidebarWidth: CGFloat = 304

    // Right panel
    public var rightPanelMode: RightPanelMode?
    public var rightPanelVisible: Bool { rightPanelMode != nil }
    public var rightSidebarWidth: CGFloat = 360

    // Terminal
    public var terminalOpen: Bool = false
    public var terminalHeight: CGFloat = 360

    // Session
    private let session: LanguageModelSession

    public init() {
        let config = LlamaConfiguration(
            modelName: "/Users/granvalenti/.modelli/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
            temperature: 0.0,
            baseURL: LlamaConfiguration.defaultURL
        )
        let model = LlamaModel(configuration: config)
        self.session = LanguageModelSession(model: model)
    }

    // MARK: - Actions

    public func selectThread(_ id: String) async {
        activeThreadId = id
    }

    public func createThread(title: String = "New Chat", mode: ThreadMode = .agent) async {
        let thread = Thread(title: title, mode: mode)
        threads.insert(thread, at: 0)
        activeThreadId = thread.id
    }

    public func renameThread(id: String, title: String) async {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].title = title
        threads[i].updatedAt = .now
    }

    public func pinThread(id: String, pinned: Bool) async {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].isPinned = pinned
        threads[i].updatedAt = .now
    }

    public func archiveThread(id: String) async {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].isArchived = true
        threads[i].updatedAt = .now
    }

    public func deleteThread(id: String) async {
        threads.removeAll { $0.id == id }
        if activeThreadId == id { activeThreadId = threads.first?.id }
    }

    public func restoreThread(id: String) async {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].isArchived = false
        threads[i].updatedAt = .now
    }

    public func sendMessage(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        blocks.append(ChatBlock(kind: .user, text: text))

        let placeholderId = UUID().uuidString
        blocks.append(ChatBlock(id: placeholderId, kind: .assistant, text: "", model: composerModel))

        busy = true
        runtimeStatus = .ready
        error = nil

        do {
            let stream = session.streamResponse(to: text)
            var accumulatedText = ""

            for try await snapshot in stream {
                // Fast path: update liveAssistant for quick UI feedback
                // (re-renders only the live block, not the entire List)
                if !snapshot.content.isEmpty {
                    accumulatedText = snapshot.content
                    liveAssistant = accumulatedText
                }

                // Reasoning from transcript — use = not += to avoid duplicates
                // (transcript already has accumulated text)
                for entry in snapshot.transcriptEntries {
                    if case .reasoning(let reasoning) = entry {
                        for segment in reasoning.segments {
                            if case .text(let t) = segment {
                                liveReasoning = t.content
                            }
                        }
                    }
                }

                // Update the blocks array (triggers full List re-render)
                // Keep this lightweight: just the placeholder replacement
                if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                    blocks[i] = ChatBlock(
                        id: placeholderId,
                        kind: .assistant,
                        text: accumulatedText,
                        model: composerModel
                    )
                }
            }

            // Post-stream: handle reasoning-only responses
            if !liveReasoning.isEmpty {
                if accumulatedText.isEmpty {
                    // Model output only reasoning (e.g. Gemma QAT).
                    // Promote reasoning as the assistant's final text.
                    if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                        blocks[i] = ChatBlock(
                            id: placeholderId,
                            kind: .assistant,
                            text: liveReasoning,
                            model: composerModel
                        )
                    }
                } else {
                    // Model output both reasoning AND content.
                    // Show reasoning as a separate expandable block.
                    if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                        blocks.insert(
                            ChatBlock(kind: .reasoning, text: liveReasoning, model: composerModel),
                            at: i
                        )
                    }
                }
                liveReasoning = ""
            }
            liveAssistant = ""  // hide live streaming block

            if let i = threads.firstIndex(where: { $0.id == activeThreadId }) {
                threads[i].updatedAt = .now
            }
        } catch {
            self.error = error.localizedDescription
            if let i = blocks.firstIndex(where: { $0.id == placeholderId }) {
                blocks[i] = ChatBlock(
                    id: placeholderId,
                    kind: .assistant,
                    text: "Error: \(error.localizedDescription)",
                    model: composerModel
                )
            }
        }

        busy = false
    }

    public func interrupt() {
        busy = false
    }

    public func setRoute(_ route: AppRoute) {
        self.route = route
        if route != .chat { rightPanelMode = nil }
    }

    public func toggleRightPanel(_ mode: RightPanelMode) {
        rightPanelMode = rightPanelMode == mode ? nil : mode
    }

    public func toggleTerminal() { terminalOpen.toggle() }

    public func toggleLeftSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) { leftSidebarCollapsed.toggle() }
    }

    // MARK: - Sorted Threads

    public var sortedThreads: [Thread] {
        let q = threadSearch.lowercased().trimmingCharacters(in: .whitespaces)
        let filtered = threads.filter { t in showArchivedThreads ? true : !t.isArchived }
            .filter { t in q.isEmpty ? true : t.title.lowercased().contains(q) }
        return filtered.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }
}

// MARK: - Runtime status

public enum RuntimeStatus: String, Sendable, Hashable {
    case disconnected; case connecting; case ready; case error
}
public enum RuntimeConnectionState: String, Sendable, Hashable {
    case disconnected; case connecting; case ready
}
