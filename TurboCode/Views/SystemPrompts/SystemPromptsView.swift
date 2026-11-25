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
    /// The profile segment the user picked; nil follows the current session.
    @State private var scope: SystemPromptProfile?
    /// Hidden for good once the user closes it: the page is visited often
    /// and the explanation is only needed the first times.
    @AppStorage("systemPrompts.introDismissed") private var introDismissed = false

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
        let scope = scope ?? currentProfile
        VStack(alignment: .leading, spacing: 16) {
            header(scope: scope)
            if !introDismissed { introCard }

            HStack {
                Spacer()
                SortMenu(selection: $model.sortOrder)
            }

            // Pick-to-use, like the wallpaper gallery in System Settings: the
            // ringed card is what `scope` sessions use, a click on another
            // card switches to it, and the default is one card among them so
            // going back is the same gesture.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                SystemPromptCard(
                    name: "TurboCode default",
                    meta: "\(tokenText(defaultTotal)) · built in",
                    isBuiltIn: true,
                    areaTokens: SystemPromptTemplates.editableTokenEstimates(.turboCodeDefault, tuning: settings.agentTuning),
                    totalTokens: defaultTotal,
                    inUseFor: model.assignments.promptIDs[scope] == nil ? scope : nil,
                    onUse: { model.assign(scope, to: nil) },
                    onEdit: { editing = .builtIn }
                )
                .contextMenu {
                    Button("Open") { editing = .builtIn }
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
                        rating: Self.ratingText(model.ratingSummary(for: record)),
                        inUseFor: model.assignments.promptIDs[scope] == record.id ? scope : nil,
                        onUse: { model.assign(scope, to: record.id) },
                        onEdit: { editing = .record(record.id) }
                    )
                    .contextMenu {
                        Button("Edit") { editing = .record(record.id) }
                        Button("Try in a New Chat") { Task { await chatStore.startPromptTrial(record) } }
                            .disabled(chatStore.busy)
                        Button("Rename…") {
                            renameText = record.name
                            renaming = record
                        }
                        Button("Duplicate") { model.duplicate(record.id) }
                        Divider()
                        Button("Delete…", role: .destructive) { deleting = record }
                    }
                }

                newPromptCard(model)
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

    /// The profile whose prompt the gallery shows: the kind of session the
    /// user is in, until they pick another segment.
    private var currentProfile: SystemPromptProfile {
        chatStore.activeDomain == .cowork ? .studio : .coding
    }

    private func header(scope: SystemPromptProfile) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("System Prompts").font(AppTypography.pageTitle)
                Text("Choose the prompt each kind of session uses. \(scope.detail).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Picker("Profile", selection: Binding(
                get: { scope },
                set: { self.scope = $0 }
            )) {
                ForEach(SystemPromptProfile.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    /// What a system prompt is for and what it cannot change. The limits
    /// matter as much as the uses: the prompt steers the model but never
    /// adds tools or loosens approvals, which stay in the managed areas.
    private var introCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.badge.star")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Make TurboCode work your way")
                    .fontWeight(.semibold)
                Text("A system prompt is what the model reads before every conversation. Write your own to give it a personality, a routine to follow (for example, \u{201C}at the start of a session, read MEMORY.md\u{201D}), or rules about which tools to prefer and when. TurboCode keeps its tool rules, approvals and session details in the gray, locked part: your prompt shapes how the model works, not what it\u{2019}s allowed to do.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("To write one with the model\u{2019}s help, turn on System Prompt Builder in")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Connectors") { chatStore.workbenchStore.setRoute(.connectors) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
            Spacer(minLength: 0)
            Button {
                introDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Hide this explanation")
            .accessibilityLabel("Hide explanation")
        }
        .padding(16)
        .background(AppSurface.card, in: .rect(cornerRadius: AppSurface.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppSurface.cardCornerRadius)
                .strokeBorder(.separator)
        }
    }

    /// The last tile of the grid. Creating a prompt is an act on the
    /// library, so it sits with the prompts instead of as a page button.
    private func newPromptCard(_ model: SystemPromptLibraryViewModel) -> some View {
        Menu {
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
        } label: {
            Label("New Prompt", systemImage: "plus")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 128)
                .contentShape(.rect)
                .overlay {
                    RoundedRectangle(cornerRadius: AppSurface.cardCornerRadius)
                        .strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func open(_ record: SystemPromptRecord?) {
        if let record { editing = .record(record.id) }
    }

    private var defaultTotal: Int {
        SystemPromptTemplates.totalTokenEstimate(.turboCodeDefault, tuning: settings.agentTuning)
    }

    /// "★ 4.3 · 3 ratings" for the current version, or an invitation.
    static func ratingText(_ summary: SystemPromptRatingSummary?) -> String {
        guard let summary else { return "Not rated · try it to rate" }
        let average = summary.average.formatted(.number.precision(.fractionLength(1)))
        return "\u{2605} \(average) \u{00B7} \(summary.count) rating\(summary.count == 1 ? "" : "s")"
    }

    private func tokenText(_ tokens: Int) -> String {
        "\(tokens.formatted()) tok"
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
/// size and version. A click puts it in use for the profile the page shows
/// (a ring marks that one); a double click or the hover button opens it.
private struct SystemPromptCard: View {
    let name: String
    let meta: String
    let isBuiltIn: Bool
    let areaTokens: [(area: SystemPromptArea, tokens: Int)]
    let totalTokens: Int
    /// Nil for the built-in default, which is not rated.
    var rating: String? = nil
    /// The profile this card is in use for, or nil.
    let inUseFor: SystemPromptProfile?
    let onUse: () -> Void
    let onEdit: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SystemPromptThumbnail(areaTokens: areaTokens, managedTokens: managedTokens)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.semibold).lineLimit(2)
                        .help(name)
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
                if let rating {
                    Text(rating)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let inUseFor {
                    Label("In use for \(inUseFor.title)", systemImage: "checkmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                } else if hovered {
                    Text("Click to use · double-click to open")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(height: 128)
        .background(AppSurface.card, in: .rect(cornerRadius: AppSurface.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppSurface.cardCornerRadius)
                .strokeBorder(
                    inUseFor == nil ? AnyShapeStyle(.separator) : AnyShapeStyle(Color.accentColor),
                    lineWidth: inUseFor == nil ? 1 : 2
                )
        }
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button(isBuiltIn ? "Open" : "Edit", action: onEdit)
                    .controlSize(.small)
                    .padding(8)
            }
        }
        .contentShape(.rect(cornerRadius: AppSurface.cardCornerRadius))
        // Double click first, so a single click waits to tell them apart.
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(perform: onUse)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(inUseFor == nil ? .isButton : [.isButton, .isSelected])
        .accessibilityHint("Uses this prompt. Double-click to open it.")
        .accessibilityAction(named: isBuiltIn ? "Open" : "Edit", onEdit)
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

/// Sort order as quiet text with a trailing chevron. One `Text` holds both,
/// so the chevron cannot be moved before the value as a menu label's
/// separate image was.
private struct SortMenu: View {
    @Binding var selection: SystemPromptLibraryViewModel.SortOrder

    var body: some View {
        Menu {
            Picker("Sort", selection: $selection) {
                ForEach(SystemPromptLibraryViewModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text("Sort by \(selection.rawValue) \(Image(systemName: "chevron.down"))")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Sort")
        .accessibilityValue(selection.rawValue)
    }
}
