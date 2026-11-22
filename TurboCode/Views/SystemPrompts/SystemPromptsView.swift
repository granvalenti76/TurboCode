import SwiftUI
import UniformTypeIdentifiers

// MARK: - SystemPromptsView

/// The System Prompts page of the main window: the library of saved prompts
/// and the profile assignments (design flow 1), and the editor (flow 2).
///
/// It lives beside Connectors and Profiles instead of in Settings, so the
/// editor gets the main window's width and the feature reads as part of the
/// product. The page header follows the other main-window pages.
struct SystemPromptsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @State private var model: SystemPromptLibraryViewModel?
    @State private var importing = false
    @State private var renaming: SystemPromptRecord?
    @State private var renameText = ""
    @State private var deleting: SystemPromptRecord?
    @State private var editing: SystemPromptEditorView.Target?

    var body: some View {
        ScrollView {
            if let model, let editing {
                SystemPromptEditorView(target: editing, model: model) { self.editing = nil }
                    .frame(maxWidth: 1240)
                    .frame(maxWidth: .infinity)
            } else if let model {
                content(model)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard model == nil else { return }
            let chatStore = chatStore
            let created = SystemPromptLibraryViewModel {
                Task { await chatStore.reloadSystemPrompts() }
            }
            created.load()
            model = created
        }
    }

    @ViewBuilder
    private func content(_ model: SystemPromptLibraryViewModel) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            header(model)
            SystemPromptAssignmentsCard(model: model)

            HStack(alignment: .firstTextBaseline) {
                Text("Prompts").font(.headline)
                Spacer()
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(SystemPromptLibraryViewModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                SystemPromptCard(
                    name: "TurboCode default",
                    meta: "\(tokenText(defaultTotal)) · built in",
                    isBuiltIn: true,
                    areaTokens: SystemPromptTemplates.editableTokenEstimates(.turboCodeDefault, tuning: settings.agentTuning),
                    totalTokens: defaultTotal,
                    profiles: model.profiles(using: nil)
                )
                .onTapGesture { editing = .builtIn }
                .contextMenu {
                    Button("Duplicate") { model.create(.duplicateDefault, tuning: settings.agentTuning) }
                }

                ForEach(model.sortedRecords) { record in
                    let total = SystemPromptTemplates.totalTokenEstimate(record.document, tuning: settings.agentTuning)
                    SystemPromptCard(
                        name: record.name,
                        meta: "\(tokenText(total)) · v\(record.version)",
                        isBuiltIn: false,
                        areaTokens: SystemPromptTemplates.editableTokenEstimates(record.document, tuning: settings.agentTuning),
                        totalTokens: total,
                        profiles: model.profiles(using: record.id)
                    )
                    .onTapGesture { editing = .record(record.id) }
                    .contextMenu {
                        Button("Rename…") {
                            renameText = record.name
                            renaming = record
                        }
                        Button("Duplicate") { model.duplicate(record.id) }
                        Divider()
                        Button("Delete…", role: .destructive) { deleting = record }
                    }
                }
            }
        }
        .frame(maxWidth: 1100, alignment: .leading)
        .frame(maxWidth: .infinity)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        ) { result in
            if case .success(let url) = result { open(model.importMarkdown(from: url)) }
        }
        .alert("Rename Prompt", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renaming { model.rename(renaming.id, to: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let deleting { model.delete(deleting.id) }
            }
        } message: {
            if let deleting, !model.profiles(using: deleting.id).isEmpty {
                Text("Profiles using it go back to the TurboCode default. This cannot be undone.")
            } else {
                Text("This cannot be undone.")
            }
        }
        .alert("System Prompts", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func header(_ model: SystemPromptLibraryViewModel) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("System Prompts").font(AppTypography.pageTitle)
                Text("Build your own prompts from blocks. Each profile uses one; the TurboCode default is always there to fall back on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu("New Prompt") {
                Button {
                    open(model.create(.duplicateDefault, tuning: settings.agentTuning))
                } label: {
                    Text("Duplicate TurboCode default")
                    Text("Start from the blocks it ships with")
                }
                Button {
                    open(model.create(.blank, tuning: settings.agentTuning))
                } label: {
                    Text("Blank prompt")
                    Text("Identity block only; managed parts are added")
                }
                Divider()
                Button {
                    importing = true
                } label: {
                    Text("Import Markdown…")
                    Text("Each ## heading becomes a block")
                }
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
        }
    }

    private func open(_ record: SystemPromptRecord?) {
        if let record { editing = .record(record.id) }
    }

    private var defaultTotal: Int {
        SystemPromptTemplates.totalTokenEstimate(.turboCodeDefault, tuning: settings.agentTuning)
    }

    private func tokenText(_ tokens: Int) -> String {
        "\(tokens.formatted()) tok"
    }
}

// MARK: - Assignments

/// "Used by profiles": one row per profile with a picker of every prompt.
private struct SystemPromptAssignmentsCard: View {
    let model: SystemPromptLibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Used by profiles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            ForEach(Array(SystemPromptProfile.allCases.enumerated()), id: \.element) { index, profile in
                if index > 0 { Divider().padding(.leading, 16) }
                HStack(spacing: 12) {
                    Text(profile.title)
                        .fontWeight(.medium)
                        .frame(width: 90, alignment: .leading)
                    Text(profile.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Prompt for \(profile.title)", selection: Binding(
                        get: { model.assignments.promptIDs[profile] },
                        set: { model.assign(profile, to: $0) }
                    )) {
                        Text("TurboCode default").tag(UUID?.none)
                        if !model.records.isEmpty { Divider() }
                        ForEach(model.records) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
            }
        }
        .padding(.bottom, 4)
        .background(AppSurface.card, in: .rect(cornerRadius: AppSurface.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppSurface.cardCornerRadius)
                .strokeBorder(.separator)
        }
    }
}

extension SystemPromptProfile {
    var title: String {
        switch self {
        case .coding: "Coding"
        case .studio: "Studio"
        case .delegate: "Delegate"
        }
    }

    /// Says where the prompt applies, so "Coding" is not read as one model.
    var detail: String {
        switch self {
        case .coding: "Coding sessions and the coordinator"
        case .studio: "Studio sessions"
        case .delegate: "Workers that run delegated tasks"
        }
    }
}

// MARK: - Card

/// One prompt in the library grid: thumbnail of the context square, name,
/// size and version, and the profiles that use it.
private struct SystemPromptCard: View {
    let name: String
    let meta: String
    let isBuiltIn: Bool
    let areaTokens: [(area: SystemPromptArea, tokens: Int)]
    let totalTokens: Int
    let profiles: [SystemPromptProfile]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SystemPromptThumbnail(areaTokens: areaTokens, managedTokens: managedTokens)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.semibold).lineLimit(1)
                    if isBuiltIn {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Read-only")
                    }
                }
                Text(meta)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                // Ratings arrive with Try & Rate; until then the card says how
                // to get one instead of showing empty stars.
                Text(isBuiltIn ? "Not rated" : "Try it to rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !profiles.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(profiles, id: \.self) { profile in
                            Text(profile.title)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: .capsule)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(height: 128)
        .background(AppSurface.card, in: .rect(cornerRadius: AppSurface.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppSurface.cardCornerRadius)
                .strokeBorder(.separator)
        }
        .accessibilityElement(children: .combine)
    }

    private var managedTokens: Int {
        max(0, totalTokens - areaTokens.reduce(0) { $0 + $1.tokens })
    }
}

/// The context square at thumbnail size: each area is a tile whose area is
/// proportional to its tokens, packed in reading order, then one gray tile
/// for everything TurboCode manages. Scaled to a 32K reference window so
/// cards compare at a glance; the editor uses the model's real window.
struct SystemPromptThumbnail: View {
    let areaTokens: [(area: SystemPromptArea, tokens: Int)]
    let managedTokens: Int
    var side: CGFloat = 104
    static let referenceContext = 32_768.0

    var body: some View {
        let tiles = layout()
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.background.secondary)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
            ForEach(tiles.indices, id: \.self) { index in
                let tile = tiles[index]
                RoundedRectangle(cornerRadius: max(1, tile.size * 0.22))
                    .fill(tile.color.gradient)
                    .frame(width: tile.size, height: tile.size)
                    .offset(x: tile.origin.x, y: tile.origin.y)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private struct Tile {
        let origin: CGPoint
        let size: CGFloat
        let color: Color
    }

    /// Shelf packing: left to right, wrapping to a new row when full.
    private func layout() -> [Tile] {
        let inset: CGFloat = 6, gap: CGFloat = 3
        var parts = areaTokens.map { ($0.tokens, $0.area.tint) }
        if managedTokens > 0 { parts.append((managedTokens, Color.gray)) }
        var tiles: [Tile] = []
        var x = inset, y = inset, rowHeight: CGFloat = 0
        for (tokens, color) in parts {
            let size = max(3, (side * sqrt(Double(tokens) / Self.referenceContext)).rounded())
            if x + size > side - inset, x > inset {
                x = inset
                y += rowHeight + gap
                rowHeight = 0
            }
            tiles.append(Tile(origin: CGPoint(x: x, y: y), size: size, color: color))
            x += size + gap
            rowHeight = max(rowHeight, size)
        }
        return tiles
    }
}

extension SystemPromptArea {
    /// The tile color of an area, from the system palette like Settings
    /// icons. Managed areas are gray, so "yours" and "TurboCode's" read apart.
    var tint: Color {
        switch self {
        case .identity: .blue
        case .personality: .purple
        case .communication: .orange
        case .workingMethod: .green
        case .userContext: .teal
        case .rules: .pink
        case .examples: .yellow
        case .aboutApp, .reasoning, .tools, .catalogs, .session, .finalReminder: .gray
        }
    }

    var systemImage: String {
        switch self {
        case .identity: "person.crop.circle"
        case .personality: "sparkles"
        case .communication: "text.bubble"
        case .workingMethod: "hammer"
        case .userContext: "square.stack.3d.up"
        case .rules: "checklist"
        case .examples: "text.quote"
        case .aboutApp: "info.circle"
        case .reasoning: "lightbulb"
        case .tools: "wrench.and.screwdriver"
        case .catalogs: "books.vertical"
        case .session: "folder"
        case .finalReminder: "bell"
        }
    }
}
