import FoundationModels
import SwiftUI

// MARK: - SystemPromptEditorView

/// The prompt editor (design flow 2, "labels with leader lines").
///
/// A large square stands for the model's whole context window. Every block
/// of the prompt is a tile whose area is proportional to its tokens; the
/// user's blocks are labelled on the left in reading order, TurboCode's
/// managed areas on the right. The strip below edits the selected block.
///
/// Edits stay in a draft until Save, which writes one new version: saving per
/// keystroke would inflate the version count and, for a prompt in use,
/// rebuild the session while the user types.
struct SystemPromptEditorView: View {
    enum Target: Hashable {
        case builtIn
        case record(UUID)
    }

    let target: Target
    let model: SystemPromptLibraryViewModel
    let onClose: () -> Void

    @Environment(SettingsStore.self) private var settings
    @Environment(ChatStore.self) private var chatStore
    @State private var name = ""
    @State private var draft = SystemPromptDocument()
    @State private var selection: SystemPromptEditorItem.ID?
    @State private var confirmingClose = false

    private var record: SystemPromptRecord? {
        if case .record(let id) = target { model.record(id) } else { nil }
    }

    private var isReadOnly: Bool { target == .builtIn }

    private var hasChanges: Bool {
        guard let record else { return false }
        return draft != record.document || name != record.name
    }

    var body: some View {
        let layout = SystemPromptEditorLayout(
            document: draft,
            context: SystemPromptTemplates.editorContext(tuning: settings.agentTuning, document: draft),
            contextWindow: contextWindow
        )
        VStack(alignment: .leading, spacing: 14) {
            breadcrumb
            header(layout)
            SystemPromptSquare(layout: layout, selection: $selection)
                .frame(height: 460)
            SystemPromptBlockStrip(
                item: layout.item(selection),
                isReadOnly: isReadOnly,
                draft: $draft,
                selection: $selection
            )
            .frame(minHeight: 180)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .onAppear(perform: loadDraft)
        .onChange(of: target) { loadDraft() }
        .confirmationDialog("Save changes to “\(name)”?", isPresented: $confirmingClose) {
            Button("Save") { save(); onClose() }
            Button("Discard Changes", role: .destructive) { onClose() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Header

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button {
                if hasChanges { confirmingClose = true } else { onClose() }
            } label: {
                Label("System Prompts", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            Text("/").foregroundStyle(.tertiary)
            Text(isReadOnly ? "TurboCode default" : name).fontWeight(.semibold)
        }
    }

    private func header(_ layout: SystemPromptEditorLayout) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if isReadOnly {
                    Text("TurboCode default").font(AppTypography.pageTitle)
                } else {
                    TextField("Prompt name", text: $name)
                        .textFieldStyle(.plain)
                        .font(AppTypography.pageTitle)
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isReadOnly {
                Button("Duplicate to Edit") {
                    model.create(.duplicateDefault, tuning: settings.agentTuning)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Menu("Add Block") {
                    ForEach(SystemPromptArea.editableAreas, id: \.self) { area in
                        Button(area.title) { addBlock(to: area, layout: layout) }
                    }
                }
                .fixedSize()
                useForProfileMenu
                Button("Revert") { loadDraft() }
                    .disabled(!hasChanges)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!hasChanges)
            }
        }
    }

    private var subtitle: String {
        guard let record else { return "Built in · read-only · always available to fall back on" }
        var parts = ["v\(record.version)"]
        if record.basedOnDefault { parts.append("from TurboCode default") }
        if hasChanges { parts.append("unsaved changes") }
        return parts.joined(separator: " · ")
    }

    /// Assigns the saved version to a profile. Disabled while there are
    /// unsaved edits, so a profile never silently gets an older version.
    private var useForProfileMenu: some View {
        Menu("Use for Profile") {
            ForEach(SystemPromptProfile.allCases, id: \.self) { profile in
                let inUse = record.map { model.profiles(using: $0.id).contains(profile) } ?? false
                Toggle(profile.title, isOn: Binding(
                    get: { inUse },
                    set: { model.assign(profile, to: $0 ? record?.id : nil) }
                ))
            }
        }
        .fixedSize()
        .disabled(hasChanges)
        .help(hasChanges ? "Save first, so the profile uses what you see." : "Choose the profiles that use this prompt.")
    }

    // MARK: Draft

    private func loadDraft() {
        switch target {
        case .builtIn:
            name = "TurboCode default"
            draft = .turboCodeDefault
        case .record:
            name = record?.name ?? ""
            draft = record?.document ?? SystemPromptDocument()
        }
        if selection == nil {
            selection = SystemPromptEditorItem.ID.area(.identity)
        }
    }

    /// Adding to an area still at its default keeps that text as the first
    /// block, so nothing the user did not touch disappears.
    private func addBlock(to area: SystemPromptArea, layout: SystemPromptEditorLayout) {
        var blocks = draft.blocks(for: area) ?? layout.item(.area(area)).map {
            [SystemPromptBlock(title: area.title, text: $0.text)]
        } ?? []
        let block = SystemPromptBlock(title: "New block", text: "")
        blocks.append(block)
        draft.setBlocks(blocks, for: area)
        selection = .block(area, block.id)
    }

    private func save() {
        guard let record else { return }
        model.rename(record.id, to: name)
        model.updateDocument(record.id, to: draft)
    }

    /// The active model's window, or a 32K reference when unknown, so the
    /// square still compares blocks meaningfully.
    private var contextWindow: (tokens: Int, isKnown: Bool) {
        let runtime = chatStore.modelRuntimeStore
        if runtime.activeBackend == .foundationApple {
            let size = SystemLanguageModel.default.contextSize
            if size > 0 { return (size, true) }
        } else if let size = runtime.activeRemoteModel?.contextWindowTokens, size > 0 {
            return (size, true)
        }
        return (32_768, false)
    }
}

// MARK: - Items and layout

/// One labelled tile in the editor: a user block, an area still at its
/// default text, or a managed area.
struct SystemPromptEditorItem: Identifiable {
    enum ID: Hashable {
        /// An editable area that still uses TurboCode's text.
        case area(SystemPromptArea)
        case block(SystemPromptArea, UUID)
        case managed(SystemPromptArea)
        case toolSchemas
    }

    let id: ID
    let area: SystemPromptArea
    let title: String
    let text: String
    let tokens: Int
    /// 1-based reading position among the user's items; nil for managed ones.
    let readingOrder: Int?
    /// An editable area the user emptied: listed so it can be reset, but it
    /// sends nothing and has no tile.
    var isRemoved = false

    var isManaged: Bool { area.isManaged }
    var isDefault: Bool {
        if case .area = id { !isRemoved } else { false }
    }
}

/// Splits the prompt into the editor's items and sizes the square.
struct SystemPromptEditorLayout {
    let yours: [SystemPromptEditorItem]
    let managed: [SystemPromptEditorItem]
    let contextWindow: Int
    let isWindowKnown: Bool

    init(
        document: SystemPromptDocument,
        context: TurboCodeSystemPromptContext,
        contextWindow: (tokens: Int, isKnown: Bool)
    ) {
        func tokens(_ text: String) -> Int { CapabilityContextEstimate.estimatedTokens(for: text) }
        var yours: [SystemPromptEditorItem] = []
        for area in SystemPromptArea.editableAreas {
            if let blocks = document.blocks(for: area) {
                if blocks.isEmpty {
                    yours.append(SystemPromptEditorItem(
                        id: .area(area), area: area, title: area.title,
                        text: "", tokens: 0, readingOrder: nil, isRemoved: true
                    ))
                }
                for block in blocks {
                    yours.append(SystemPromptEditorItem(
                        id: .block(area, block.id), area: area, title: block.title,
                        text: block.text, tokens: max(1, tokens(block.text)),
                        readingOrder: yours.filter { !$0.isRemoved }.count + 1
                    ))
                }
            } else {
                let text = TurboCodeSystemPromptBuilder.defaultText(for: area, context: context)
                guard !text.isEmpty else { continue }
                yours.append(SystemPromptEditorItem(
                    id: .area(area), area: area, title: area.title,
                    text: text, tokens: tokens(text),
                    readingOrder: yours.filter { !$0.isRemoved }.count + 1
                ))
            }
        }

        var managedText: [SystemPromptArea: [String]] = [:]
        for section in TurboCodeSystemPromptBuilder.sections(context) where section.area.isManaged {
            managedText[section.area, default: []].append(section.text)
        }
        var managed = SystemPromptArea.allCases.filter(\.isManaged).compactMap { area -> SystemPromptEditorItem? in
            guard let texts = managedText[area] else { return nil }
            let text = texts.joined(separator: "\n\n")
            return SystemPromptEditorItem(
                id: .managed(area), area: area, title: area.title,
                text: text, tokens: tokens(text), readingOrder: nil
            )
        }
        // Tool definitions travel beside the prompt, not inside it, but they
        // fill the same window; measured sizes are used once a session has
        // registered the tools.
        let schemas = CapabilityContextEstimate(
            tools: SystemPromptTemplates.referenceCodingToolIDs.map(ModelToolCatalog.descriptor(for:)),
            skills: [],
            measuredToolTokens: ToolDefinitionSizeStore.shared.tokensByToolName,
            contextSize: nil
        )
        if schemas.toolTokens > 0 {
            let index = managed.firstIndex { $0.area == .tools }.map { $0 + 1 } ?? managed.count
            managed.insert(SystemPromptEditorItem(
                id: .toolSchemas, area: .tools, title: "Tool schemas",
                text: "Names, descriptions, and argument schemas of the \(SystemPromptTemplates.referenceCodingToolIDs.count) tools a default Coding session registers. Sent beside the prompt; the exact list depends on the model and profile.",
                tokens: schemas.toolTokens, readingOrder: nil
            ), at: min(index, managed.count))
        }

        self.yours = yours
        self.managed = managed
        self.contextWindow = contextWindow.tokens
        self.isWindowKnown = contextWindow.isKnown
    }

    var totalTokens: Int { (yours + managed).reduce(0) { $0 + $1.tokens } }
    var freeTokens: Int { max(0, contextWindow - totalTokens) }

    func item(_ id: SystemPromptEditorItem.ID?) -> SystemPromptEditorItem? {
        guard let id else { return nil }
        return (yours + managed).first { $0.id == id }
    }
}

// MARK: - Square

/// The context square with labels and leader lines.
private struct SystemPromptSquare: View {
    let layout: SystemPromptEditorLayout
    @Binding var selection: SystemPromptEditorItem.ID?

    private let labelWidth: CGFloat = 200
    private let labelHeight: CGFloat = 36

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let side = max(180, min(height - 48, width - 2 * labelWidth - 64))
            let origin = CGPoint(x: (width - side) / 2, y: 32)
            let tiles = tilePositions(side: side, origin: origin)
            let left = labelPositions(count: layout.yours.count, x: 16, height: height)
            let right = labelPositions(count: layout.managed.count, x: width - 16 - labelWidth, height: height)

            ZStack(alignment: .topLeading) {
                // Grid square.
                RoundedRectangle(cornerRadius: 8)
                    .fill(.background.secondary)
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
                    .frame(width: side, height: side)
                    .offset(x: origin.x, y: origin.y)

                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(layout.freeTokens.formatted()) free")
                        .font(.custom("New York", size: 26, relativeTo: .title).weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("for the conversation")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: side - 24, alignment: .trailing)
                .offset(x: origin.x, y: origin.y + side - 64)
                .accessibilityElement(children: .combine)

                // Leader lines under the tiles and labels.
                Canvas { context, _ in
                    for (index, item) in layout.yours.enumerated() {
                        line(context, from: CGPoint(x: 16 + labelWidth, y: left[index] + labelHeight / 2), to: tiles[item.id], item: item)
                    }
                    for (index, item) in layout.managed.enumerated() {
                        line(context, from: CGPoint(x: width - 16 - labelWidth, y: right[index] + labelHeight / 2), to: tiles[item.id], item: item)
                    }
                }
                .allowsHitTesting(false)

                ForEach(layout.yours + layout.managed) { item in
                    if let frame = tiles[item.id] {
                        tile(item, frame: frame)
                    }
                }

                ForEach(Array(layout.yours.enumerated()), id: \.element.id) { index, item in
                    label(item).offset(x: 16, y: left[index])
                }
                ForEach(Array(layout.managed.enumerated()), id: \.element.id) { index, item in
                    label(item).offset(x: width - 16 - labelWidth, y: right[index])
                }

                Text("Your blocks · in reading order")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .offset(x: 16, y: 10)
                HStack(spacing: 8) {
                    Label("Managed by TurboCode", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(layout.totalTokens.formatted()) / \(layout.contextWindow.formatted()) tok")
                        .font(.caption.monospaced())
                        .help(layout.isWindowKnown
                              ? "Estimated at four characters per token."
                              : "The active model's window is unknown; a 32K reference is shown.")
                }
                .frame(width: width - 32, alignment: .trailing)
                .offset(x: 16, y: 10)
            }
        }
        .background(AppSurface.card, in: .rect(cornerRadius: AppSurface.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppSurface.cardCornerRadius).strokeBorder(.separator)
        }
    }

    private func line(_ context: GraphicsContext, from start: CGPoint, to frame: CGRect?, item: SystemPromptEditorItem) {
        guard let frame else { return }
        let end = CGPoint(x: frame.midX, y: frame.midY)
        let selected = item.id == selection
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        let color: Color = selected ? .accentColor : Color.secondary.opacity(0.35)
        context.stroke(path, with: .color(color), lineWidth: selected ? 1.5 : 1)
        context.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)), with: .color(color))
    }

    private func tile(_ item: SystemPromptEditorItem, frame: CGRect) -> some View {
        Button {
            selection = item.id
        } label: {
            RoundedRectangle(cornerRadius: frame.width * 0.225)
                .fill(item.area.tint.gradient.opacity(item.isDefault ? 0.75 : 1))
                .overlay {
                    if frame.width >= 16 {
                        Image(systemName: item.area.systemImage)
                            .font(.system(size: frame.width * 0.45, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                .overlay {
                    if item.id == selection {
                        RoundedRectangle(cornerRadius: frame.width * 0.225 + 3)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-4)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
        .accessibilityLabel("\(item.title), \(item.tokens) tokens")
    }

    private func label(_ item: SystemPromptEditorItem) -> some View {
        let selected = item.id == selection
        return Button {
            selection = item.id
        } label: {
            HStack(spacing: 8) {
                Text(item.readingOrder.map(String.init) ?? "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(item.area.tint.gradient)
                    .frame(width: 16, height: 16)
                Text(item.title)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                if item.isDefault {
                    Text("default").font(.caption2).foregroundStyle(.tertiary)
                } else if item.isRemoved {
                    Text("removed").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Text(item.tokens.formatted())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(width: labelWidth, height: labelHeight)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.clear, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2))
            }
            .background(AppSurface.card, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Vertically spaced label origins, compressed when there are many.
    private func labelPositions(count: Int, x: CGFloat, height: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let top: CGFloat = 34
        let step = min(labelHeight + 10, (height - top - labelHeight - 8) / CGFloat(max(1, count - 1)))
        return (0..<count).map { top + CGFloat($0) * step }
    }

    /// Shelf-packs tiles in reading order: yours from the top-left, managed
    /// on the rows after them. Side length ∝ √tokens, so area ∝ tokens.
    private func tilePositions(side: CGFloat, origin: CGPoint) -> [SystemPromptEditorItem.ID: CGRect] {
        let inset: CGFloat = 14, gap: CGFloat = 6
        var frames: [SystemPromptEditorItem.ID: CGRect] = [:]
        var x = inset, y = inset, rowHeight: CGFloat = 0
        func place(_ item: SystemPromptEditorItem) {
            guard !item.isRemoved else { return }
            let size = max(8, (side * sqrt(Double(item.tokens) / Double(max(1, layout.contextWindow)))).rounded())
            if x + size > side - inset, x > inset {
                x = inset
                y += rowHeight + gap
                rowHeight = 0
            }
            frames[item.id] = CGRect(x: origin.x + x, y: origin.y + y, width: size, height: size)
            x += size + gap
            rowHeight = max(rowHeight, size)
        }
        layout.yours.forEach(place)
        // Managed tiles start on a new row, so the two groups read apart.
        if rowHeight > 0 { x = inset; y += rowHeight + gap * 2; rowHeight = 0 }
        layout.managed.forEach(place)
        return frames
    }
}

// MARK: - Block strip

/// Edits the selected item. Typing into an area that still uses the default
/// turns it into a customized area with one block holding that text.
private struct SystemPromptBlockStrip: View {
    let item: SystemPromptEditorItem?
    let isReadOnly: Bool
    @Binding var draft: SystemPromptDocument
    @Binding var selection: SystemPromptEditorItem.ID?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let item {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: item.area.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(item.area.tint.gradient, in: .rect(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 1) {
                            if case .block = item.id, !isReadOnly {
                                TextField("Block name", text: titleBinding(item))
                                    .textFieldStyle(.plain)
                                    .font(.headline)
                            } else {
                                Text(item.title).font(.headline)
                            }
                            Text(detail(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(item.area.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 200, alignment: .leading)

                TextEditor(text: textBinding(item))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
                    .disabled(isReadOnly || item.isManaged)
                    .accessibilityLabel("\(item.title) text")

                VStack(alignment: .leading, spacing: 8) {
                    if !isReadOnly && !item.isManaged {
                        actions(item)
                    } else if item.isManaged {
                        Label("TurboCode writes this part from the session.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, alignment: .leading)
            } else {
                Text("Select a block in the square or a label to edit it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .background(AppSurface.card, in: .rect(cornerRadius: AppSurface.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppSurface.cardCornerRadius).strokeBorder(.separator)
        }
    }

    @ViewBuilder
    private func actions(_ item: SystemPromptEditorItem) -> some View {
        if case .block(let area, let id) = item.id {
            HStack(spacing: 4) {
                Button { move(id, in: area, by: -1) } label: { Image(systemName: "arrow.up") }
                    .help("Read earlier within \(area.title)")
                Button { move(id, in: area, by: 1) } label: { Image(systemName: "arrow.down") }
                    .help("Read later within \(area.title)")
            }
            Button("Delete Block", role: .destructive) { delete(id, in: area) }
        }
        if draft.blocks(for: item.area) != nil {
            Button("Reset Area to Default") {
                draft.resetToDefault(item.area)
                selection = .area(item.area)
            }
        }
    }

    private func detail(_ item: SystemPromptEditorItem) -> String {
        var parts: [String] = []
        if let order = item.readingOrder { parts.append("Read \(order.formatted(.number))") }
        parts.append("\(item.tokens.formatted()) tok")
        if item.isDefault { parts.append("TurboCode default") }
        if item.isRemoved { parts.append("removed; sends nothing") }
        if item.isManaged { parts.append("managed") }
        return parts.joined(separator: " · ")
    }

    private func textBinding(_ item: SystemPromptEditorItem) -> Binding<String> {
        Binding(
            get: { item.text },
            set: { newValue in
                switch item.id {
                case .area(let area):
                    // First keystroke in a default area: it becomes the
                    // user's, starting from the default text just edited.
                    let block = SystemPromptBlock(title: area.title, text: newValue)
                    draft.setBlocks([block], for: area)
                    selection = .block(area, block.id)
                case .block(let area, let id):
                    updateBlock(id, in: area) { $0.text = newValue }
                case .managed, .toolSchemas:
                    break
                }
            }
        )
    }

    private func titleBinding(_ item: SystemPromptEditorItem) -> Binding<String> {
        Binding(
            get: { item.title },
            set: { newValue in
                if case .block(let area, let id) = item.id {
                    updateBlock(id, in: area) { $0.title = newValue }
                }
            }
        )
    }

    private func updateBlock(_ id: UUID, in area: SystemPromptArea, _ change: (inout SystemPromptBlock) -> Void) {
        guard var blocks = draft.blocks(for: area), let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        change(&blocks[index])
        draft.setBlocks(blocks, for: area)
    }

    private func move(_ id: UUID, in area: SystemPromptArea, by offset: Int) {
        guard var blocks = draft.blocks(for: area), let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard blocks.indices.contains(target) else { return }
        blocks.swapAt(index, target)
        draft.setBlocks(blocks, for: area)
    }

    private func delete(_ id: UUID, in area: SystemPromptArea) {
        guard var blocks = draft.blocks(for: area) else { return }
        blocks.removeAll { $0.id == id }
        // An emptied area stays customized and renders nothing; "Reset Area
        // to Default" brings TurboCode's text back.
        draft.setBlocks(blocks, for: area)
        selection = blocks.first.map { .block(area, $0.id) } ?? .area(area)
    }
}
