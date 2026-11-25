import SwiftUI

/// The strip above a "Try" chat: which saved prompt it runs, a way to rate
/// that version, and a way to adopt it.
///
/// It says the profile keeps its prompt because that is the one thing a
/// user could get wrong here: a trial chat changes nothing else.
struct PromptTrialBanner: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var rating = false
    /// Read from disk once per chat and after each change, never in `body`:
    /// the chat view redraws on every streamed token.
    @State private var state = LoadedState()
    @State private var refresh = 0

    private struct LoadedState {
        var record: SystemPromptRecord?
        var stars: Int?
        var inUse = false
    }

    var body: some View {
        let conversation = chatStore.activeConversation
        if let conversation, let trial = conversation.promptTrial {
            HStack(spacing: 10) {
                Image(systemName: "flask")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(message(record: state.record, trial: trial))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let record = state.record {
                    if let stars = state.stars {
                        Text(String(repeating: "\u{2605}", count: stars))
                            .font(.callout)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Rated \(stars) of 5")
                    }
                    Button("Rate\u{2026}") { rating = true }
                        .popover(isPresented: $rating, arrowEdge: .bottom) {
                            PromptRatingForm(promptName: record.name, version: record.version) { stars, tags, note in
                                chatStore.ratePromptTrial(stars: stars, tags: tags, note: note)
                                refresh += 1
                                rating = false
                            }
                        }
                    if state.inUse {
                        Label("In use", systemImage: "checkmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Use This Prompt") {
                            Task {
                                await chatStore.adoptPromptTrial()
                                refresh += 1
                            }
                        }
                        .disabled(chatStore.busy)
                        .help("Make it the prompt of every \(profileTitle) session")
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .task(id: "\(conversation.id)-\(refresh)") {
                state = Self.load(trial: trial, conversationID: conversation.id, domain: conversation.domain)
            }
        }
    }

    private var profileTitle: String {
        chatStore.activeDomain == .cowork ? "Studio" : "Coding"
    }

    private func message(record: SystemPromptRecord?, trial: PromptTrial) -> String {
        guard let record else {
            return "The prompt this chat was trying was deleted; it uses the \(profileTitle) prompt again."
        }
        let changed = record.version != trial.version ? " (edited since this chat began)" : ""
        return "Trying \u{201C}\(record.name)\u{201D} v\(record.version)\(changed) \u{00B7} your profile keeps its prompt"
    }

    private static func load(trial: PromptTrial, conversationID: String, domain: SessionDomain) -> LoadedState {
        let library = SystemPromptLibrary.live
        guard let record = library.record(for: trial) else { return LoadedState() }
        let profile: SystemPromptProfile = domain == .cowork ? .studio : .coding
        // The newest rating this chat gave the current version.
        let stars = library.ratings()
            .last { $0.promptID == record.id && $0.version == record.version && $0.conversationID == conversationID }?
            .stars
        return LoadedState(
            record: record,
            stars: stars,
            inUse: library.assignments().promptIDs[profile] == record.id
        )
    }
}

/// Five stars, a few fixed reasons, and a note. Fixed reasons make ratings
/// comparable across prompts; the note is for what they do not cover.
private struct PromptRatingForm: View {
    let promptName: String
    let version: Int
    let onSave: (_ stars: Int, _ tags: [String], _ note: String) -> Void

    @State private var stars = 0
    @State private var tags: Set<String> = []
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rate \u{201C}\(promptName)\u{201D}")
                    .fontWeight(.semibold)
                Text("For version \(version), judged on this chat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { value in
                    Button {
                        stars = value
                    } label: {
                        Image(systemName: value <= stars ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(value <= stars ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(value) star\(value == 1 ? "" : "s")")
                    .accessibilityAddTraits(value == stars ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SystemPromptRating.suggestedTags, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(
                        get: { tags.contains(tag) },
                        set: { if $0 { tags.insert(tag) } else { tags.remove(tag) } }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            TextField("Note (optional)", text: $note, axis: .vertical)
                .lineLimit(2...4)
            HStack {
                Spacer()
                Button("Save Rating") {
                    // Keep the fixed order, not the click order.
                    onSave(stars, SystemPromptRating.suggestedTags.filter(tags.contains), note)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(stars == 0)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
