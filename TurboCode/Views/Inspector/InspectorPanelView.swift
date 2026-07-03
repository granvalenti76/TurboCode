import SwiftUI

// MARK: - Models

enum DiffLineType { case context; case added; case removed }

struct DiffLine: Identifiable, Hashable, Sendable {
    var id: String { "\(oldLineNumber ?? 0)-\(newLineNumber ?? 0)-\(content)" }
    let oldLineNumber: Int?; let newLineNumber: Int?
    let content: String; let type: DiffLineType
}

struct GitFileStatus: Identifiable, Hashable {
    var path: String; var added: Int; var removed: Int
    var id: String { path }
}

// MARK: - Actor con cache

actor GitDiffService {

    private var cacheChangedFiles: [String: [GitFileStatus]] = [:]
    private var cacheDiff: [String: [DiffLine]] = [:]

    func changedFiles(at url: URL) async throws -> [GitFileStatus] {
        let key = url.path
        if let cached = cacheChangedFiles[key] { return cached }

        let unstaged = try runNumstat(repo: url.path, args: ["diff", "--numstat"])
        let staged   = try runNumstat(repo: url.path, args: ["diff", "--cached", "--numstat"])

        let merged = Dictionary(grouping: unstaged + staged, by: \.path)
            .map { path, values in
                GitFileStatus(
                    path: path,
                    added: values.map(\.added).reduce(0, +),
                    removed: values.map(\.removed).reduce(0, +)
                )
            }
            .sorted { $0.path < $1.path }

        cacheChangedFiles[key] = merged
        return merged
    }

    func diff(for path: String, at repo: String) async throws -> [DiffLine] {
        let key = repo + "::" + path
        if let cached = cacheDiff[key] { return cached }

        let output = try runGit(repo: repo, args: ["diff", "--unified=5", "--", path])
        let parsed = parse(output)
        cacheDiff[key] = parsed
        return parsed
    }

    func invalidateCache(for url: URL) {
        cacheChangedFiles.removeValue(forKey: url.path)
        cacheDiff = cacheDiff.filter { !$0.key.hasPrefix(url.path + "::") }
    }

    // MARK: - Git helpers

    private func runNumstat(repo: String, args: [String]) throws -> [GitFileStatus] {
        let output = try runGit(repo: repo, args: args)
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 3, let a = Int(parts[0]), let r = Int(parts[1]) else { return nil }
            return GitFileStatus(path: String(parts[2]), added: a, removed: r)
        }
    }

    private func runGit(repo: String, args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repo] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice  // evita deadlock se git scrive su stderr
        try p.run()
        // Leggi i dati PRIMA di waitUntilExit() — evita deadlock sul buffer di stdout
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func parse(_ output: String) -> [DiffLine] {
        var r: [DiffLine] = []
        var o: Int?; var n: Int?
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("@@") {
                if let m = line.firstMatch(of: /@@[^@]*-(\d+)[^@]*\+(\d+)/) { o = Int(m.1); n = Int(m.2) }
                continue
            }
            if line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("diff --git") || line.hasPrefix("index ") { continue }
            if line.hasPrefix("+") {
                r.append(.init(oldLineNumber: nil, newLineNumber: n, content: String(line.dropFirst()), type: .added))
                n = n.map { $0 + 1 }
            } else if line.hasPrefix("-") {
                r.append(.init(oldLineNumber: o, newLineNumber: nil, content: String(line.dropFirst()), type: .removed))
                o = o.map { $0 + 1 }
            } else if line.hasPrefix(" ") {
                r.append(.init(oldLineNumber: o, newLineNumber: n, content: String(line.dropFirst()), type: .context))
                o = o.map { $0 + 1 }; n = n.map { $0 + 1 }
            }
        }
        return r
    }
}

// MARK: - InspectorPanelView

struct InspectorPanelView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var files: [GitFileStatus] = []
    @State private var selected: GitFileStatus?
    @State private var isRepo = false
    @State private var loading = true
    @State private var loadID = UUID()

    private let git = GitDiffService()

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !isRepo {
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("Choose a workspace").font(.subheadline).foregroundStyle(.secondary)
                    Text("Select a git repository").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle").font(.system(size: 32)).foregroundStyle(.green)
                    Text("No changes").font(.subheadline).foregroundStyle(.secondary)
                    Text("Working tree is clean").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                InspectorSplitView(files: files, selected: $selected, git: git, repo: chatStore.workspaceRoot)
            }
        }
        .background(.background)
        .frame(minWidth: 280)
        .task(id: chatStore.workspaceRoot) {
            let id = UUID()
            loadID = id
            loading = true
            await loadFiles(id: id)
        }
    }

    private func loadFiles(id: UUID) async {
        let root = chatStore.workspaceRoot
        guard !root.isEmpty else {
            files = []; isRepo = false; loading = false; return
        }

        do {
            let url = URL(fileURLWithPath: root)
            let result = try await git.changedFiles(at: url)

            guard id == loadID else { return }

            isRepo = true
            files = result

            if selected == nil || !result.contains(where: { $0.id == selected?.id }) {
                selected = result.first
            }

            loading = false

        } catch {
            guard id == loadID else { return }
            isRepo = false; files = []; loading = false
        }
    }
}

// MARK: - InspectorSplitView

struct InspectorSplitView: View {
    let files: [GitFileStatus]
    @Binding var selected: GitFileStatus?
    let git: GitDiffService
    let repo: String

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unstaged \(files.count)").font(.headline).padding(.horizontal).padding(.top, 12)
                List(files) { file in
                    Button {
                        selected = file
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path).font(.subheadline).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 6) {
                                Text("+\(file.added)").font(.caption).foregroundStyle(.green)
                                Text("-\(file.removed)").font(.caption).foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                }
                .listStyle(.plain)
            }
            .frame(width: 220)

            Divider()

            if let file = selected ?? files.first {
                DetailView(file: file, git: git, repo: repo)
            } else {
                Text("Select a file").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - DetailView

struct DetailView: View {
    let file: GitFileStatus
    let git: GitDiffService
    let repo: String
    @State private var lines: [DiffLine]?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.path).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("+\(file.added)").foregroundStyle(.green).font(.callout) + Text("  -\(file.removed)").foregroundStyle(.red).font(.callout)
            }
            .padding().background(.ultraThinMaterial)

            Divider()

            if loading {
                VStack(spacing: 10) {
                    ProgressView().scaleEffect(0.7)
                    Text("Loading diff…").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lines, !lines.isEmpty {
                DiffContentView(lines: lines)
            } else {
                Text("No diff output").foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: file.id) {
            loading = true
            defer { loading = false }
            do { lines = try await git.diff(for: file.path, at: repo) }
            catch { lines = [] }
        }
    }
}

// MARK: - DiffContentView

struct DiffContentView: View {
    let lines: [DiffLine]

    var body: some View {
        ScrollView(.horizontal) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    DiffLineRow(line: line)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
        }
    }
}

// MARK: - DiffLineRow

struct DiffLineRow: View {
    let line: DiffLine

    private var num: Int? {
        switch line.type {
        case .added:   return line.newLineNumber
        case .removed: return line.oldLineNumber
        case .context: return line.newLineNumber ?? line.oldLineNumber
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                Text(line.type == .added ? "+" : line.type == .removed ? "-" : " ")
                    .foregroundStyle(prefixColor).frame(width: 10)
                Text(num.map { String(format: "%3d", $0) } ?? "   ")
                    .foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
            }
            .padding(.leading, 6).padding(.trailing, 8).background(gutterBg)

            Rectangle().fill(stripeColor).frame(width: 3)
            Text(line.content).foregroundStyle(.primary)
                .padding(.leading, 10).padding(.trailing, 8).lineLimit(nil)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1).background(contentBg)
    }

    private var prefixColor: Color {
        switch line.type { case .added: return .green; case .removed: return .red; case .context: return .clear }
    }
    private var stripeColor: Color {
        switch line.type { case .added: return .green.opacity(0.5); case .removed: return .red.opacity(0.5); case .context: return .clear }
    }
    private var gutterBg: Color {
        switch line.type { case .added: return .green.opacity(0.18); case .removed: return .red.opacity(0.18); case .context: return .clear }
    }
    private var contentBg: Color {
        switch line.type { case .added: return .green.opacity(0.08); case .removed: return .red.opacity(0.08); case .context: return .clear }
    }
}
