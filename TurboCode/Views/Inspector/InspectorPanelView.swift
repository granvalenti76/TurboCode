import SwiftUI

// MARK: - Models

struct GitFileStatus: Identifiable, Hashable {
    let path: String; let added: Int; let removed: Int
    var id: String { path }
}

enum DiffLineType: Hashable, Sendable { case context; case added; case removed }

struct DiffLine: Identifiable, Hashable, Sendable {
    let id = UUID()
    let oldLineNumber: Int?; let newLineNumber: Int?
    let content: String; let type: DiffLineType
}

struct FileDiffSection: Identifiable, Hashable {
    let path: String; let added: Int; let removed: Int
    let diffLines: [DiffLine]
    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }

    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Actor (identico a Codechat)

actor GitDiffService {
    enum GitError: LocalizedError {
        case notARepository; case commandFailed(String)
        var errorDescription: String? {
            switch self {
            case .notARepository: return "This directory is not a Git repository."
            case .commandFailed(let detail): return "Git command failed: \(detail)"
            }
        }
    }

    func isGitRepository(at directory: URL) -> Bool {
        shell("git", args: ["rev-parse", "--show-toplevel"], cwd: directory).exitCode == 0
    }

    func fetchChangedFiles(at url: URL) throws -> [GitFileStatus] {
        let unstaged = try parseNumstat(shell("git", args: ["diff", "--numstat"], cwd: url))
        let staged = try parseNumstat(shell("git", args: ["diff", "--cached", "--numstat"], cwd: url))
        var merged: [String: GitFileStatus] = [:]
        for status in unstaged + staged {
            if let existing = merged[status.path] {
                merged[status.path] = GitFileStatus(path: status.path, added: existing.added + status.added, removed: existing.removed + status.removed)
            } else {
                merged[status.path] = status
            }
        }
        return Array(merged.values).sorted { $0.path < $1.path }
    }

    func fetchDiff(for filePath: String, at url: URL) throws -> [DiffLine] {
        let result = shell("git", args: ["diff", "--unified=9999", "--", filePath], cwd: url)
        guard result.exitCode == 0 else { throw GitError.commandFailed(result.stderr) }
        let stagedResult = shell("git", args: ["diff", "--cached", "--unified=9999", "--", filePath], cwd: url)
        let combined = result.stdout + (stagedResult.stdout.isEmpty ? "" : "\n" + stagedResult.stdout)
        return parseDiffOutput(combined)
    }

    private func parseNumstat(_ result: ShellResult) throws -> [GitFileStatus] {
        guard result.exitCode == 0 else { throw GitError.commandFailed(result.stderr) }
        return result.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }.compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3, let added = Int(parts[0]), let removed = Int(parts[1]) else { return nil }
            return GitFileStatus(path: String(parts[2]), added: added, removed: removed)
        }
    }

    private func parseDiffOutput(_ output: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        let rawLines = output.components(separatedBy: .newlines)
        var oldLine: Int?; var newLine: Int?
        for raw in rawLines {
            guard !raw.hasPrefix("---") && !raw.hasPrefix("+++") && !raw.hasPrefix("diff --git") && !raw.hasPrefix("index ") else { continue }
            if raw.hasPrefix("@@") {
                if let match = raw.firstMatch(of: /@@[^@]*-(\d+)[^@]*\+(\d+)/) { oldLine = Int(match.1); newLine = Int(match.2) }
                continue
            }
            if raw.hasPrefix("+") {
                lines.append(DiffLine(oldLineNumber: nil, newLineNumber: newLine, content: String(raw.dropFirst()), type: .added))
                if let nl = newLine { newLine = nl + 1 }
            } else if raw.hasPrefix("-") {
                lines.append(DiffLine(oldLineNumber: oldLine, newLineNumber: nil, content: String(raw.dropFirst()), type: .removed))
                if let ol = oldLine { oldLine = ol + 1 }
            } else if raw.hasPrefix(" ") {
                lines.append(DiffLine(oldLineNumber: oldLine, newLineNumber: newLine, content: String(raw.dropFirst()), type: .context))
                if let ol = oldLine { oldLine = ol + 1 }; if let nl = newLine { newLine = nl + 1 }
            }
        }
        return lines
    }

    @discardableResult
    private func shell(_ command: String, args: [String], cwd: URL) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + args
        process.currentDirectoryURL = cwd
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe
        do { try process.run(); process.waitUntilExit() }
        catch { return ShellResult(exitCode: -1, stdout: "", stderr: error.localizedDescription) }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return ShellResult(
            exitCode: Int(process.terminationStatus),
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

private struct ShellResult { let exitCode: Int; let stdout: String; let stderr: String }

// MARK: - Loader View (copre loading/empty/errore)

struct InspectorPanelView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var sections: [FileDiffSection] = []
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var loadTask: Task<Void, Never>?

    private let service = GitDiffService()

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMsg {
                emptyView("Choose a workspace", subtitle: error)
            } else if sections.isEmpty {
                emptyView("No changes yet", subtitle: "Working tree is clean")
            } else {
                FileInspectorView(sections: sections, projectFolderURL: URL(fileURLWithPath: chatStore.workspaceRoot))
            }
        }
        .background(.background)
        .frame(minWidth: 280)
        .onAppear { startLoad() }
        .onChange(of: chatStore.workspaceRoot) { _, _ in startLoad() }
    }

    private func startLoad() {
        loadTask?.cancel()
        loadTask = Task { await load() }
    }

    private func emptyView(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle").font(.system(size: 32)).foregroundStyle(.green)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(subtitle).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        if chatStore.workspaceRoot.isEmpty {
            sections = []; errorMsg = "No workspace selected"; isLoading = false; return
        }
        isLoading = true
        defer { isLoading = false }
        errorMsg = nil
        let url = URL(fileURLWithPath: chatStore.workspaceRoot)

        do {
            let result = try await service.fetchSections(at: url)
            guard !Task.isCancelled else { return }
            sections = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMsg = error.localizedDescription
            sections = []
        }
    }
}

// MARK: - Service extension (carica tutto upfront come Codechat)

extension GitDiffService {
    func fetchSections(at url: URL) async throws -> [FileDiffSection] {
        guard isGitRepository(at: url) else { throw GitError.notARepository }

        let files = try fetchChangedFiles(at: url)
        guard !files.isEmpty else { return [] }

        var sections: [FileDiffSection] = []
        for file in files {
            let diff = try? fetchDiff(for: file.path, at: url)
            sections.append(FileDiffSection(
                path: file.path,
                added: file.added,
                removed: file.removed,
                diffLines: diff ?? []
            ))
        }
        return sections
    }
}

// MARK: - FileInspectorView (identico a Codechat)

struct FileInspectorView: View {
    let sections: [FileDiffSection]
    let projectFolderURL: URL?
    @State private var collapsed: Set<String> = []
    @State private var showOnlyChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.plaintext").font(.system(size: 10)).foregroundStyle(.secondary)
            Text("File modificati").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()

            // Toggle: mostra solo +/- nascondendo il contesto
            Button {
                showOnlyChanges.toggle()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: showOnlyChanges ? "doc.text.below.ecg" : "doc.text")
                        .font(.system(size: 9))
                    Text(showOnlyChanges ? "Changes" : "Full")
                        .font(.system(size: 9))
                }
                .foregroundStyle(showOnlyChanges ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(showOnlyChanges ? "Show full diff with context" : "Show only added/removed lines")

            Text("\(sections.count) file").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8).frame(minHeight: 36)
    }

    @ViewBuilder
    private var contentArea: some View {
        if sections.isEmpty {
            emptyPlaceholder
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(sections) { section in
                        DiffSectionView(
                            section: section,
                            isCollapsed: collapsed.contains(section.id),
                            showOnlyChanges: showOnlyChanges,
                            onToggle: { toggle(section.id) }
                        )
                        if section.id != sections.last?.id { Divider().padding(.leading, 12) }
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) }
        else { collapsed.insert(id) }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 24)).foregroundStyle(.secondary)
            Text("Nessun file modificato").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DiffSectionView

struct DiffSectionView: View {
    let section: FileDiffSection
    let isCollapsed: Bool
    let showOnlyChanges: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }

            if !isCollapsed, !section.diffLines.isEmpty {
                DiffLinesView(lines: showOnlyChanges ? onlyChanges(section.diffLines) : section.diffLines)
            }
        }
    }

    private func onlyChanges(_ lines: [DiffLine]) -> [DiffLine] {
        lines.filter { $0.type != .context }
    }

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
                .font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 10)
            Image(systemName: "doc.plaintext").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.fileName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(section.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if section.added > 0 { Text("+\(section.added)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.green) }
            if section.removed > 0 { Text("-\(section.removed)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.red) }
        }
    }
}

// MARK: - DiffLinesView

struct DiffLinesView: View {
    let lines: [DiffLine]
    @State private var contentWidth: CGFloat = 300

    var body: some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    DiffLineView(line: line)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(minWidth: contentWidth, alignment: .leading)
        }
        .overlay {
            GeometryReader { geo in
                Color.clear.task(id: geo.size.width) { contentWidth = geo.size.width }
            }
        }
    }
}

// MARK: - DiffLineView

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(prefix).foregroundStyle(prefixColor).frame(width: 10, alignment: .center)
                Text(lineNumberStr).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            }
            .padding(.leading, 6).padding(.trailing, 8).background(gutterBg)

            Rectangle().fill(stripeColor).frame(width: 3)

            Text(line.content).foregroundStyle(.primary).lineLimit(nil)
                .padding(.leading, 10).padding(.trailing, 8)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1).background(contentBg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gutterBg: Color {
        switch line.type { case .added: return .green.opacity(0.18); case .removed: return .red.opacity(0.18); case .context: return .clear }
    }
    private var contentBg: Color {
        switch line.type { case .added: return .green.opacity(0.08); case .removed: return .red.opacity(0.08); case .context: return .clear }
    }
    private var prefix: String {
        switch line.type { case .added: return "+"; case .removed: return "-"; case .context: return " " }
    }
    private var displayLineNumber: Int? {
        switch line.type { case .added: return line.newLineNumber; case .removed: return line.oldLineNumber; case .context: return line.newLineNumber ?? line.oldLineNumber }
    }
    private var lineNumberStr: String {
        guard let ln = displayLineNumber else { return " " }; return String(format: "%3d", ln)
    }
    private var prefixColor: Color {
        switch line.type { case .added: return .green; case .removed: return .red; case .context: return .clear }
    }
    private var stripeColor: Color {
        switch line.type { case .added: return .green.opacity(0.5); case .removed: return .red.opacity(0.5); case .context: return .clear }
    }
}
