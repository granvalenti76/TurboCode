import Foundation

/// Read-only, provider-neutral view of the active conversation exposed to a
/// TypeScript plugin. It deliberately contains timeline values rather than a
/// Foundation Models `Transcript`, which also makes it available to Codex and
/// to sessions that have not yet been persisted.
nonisolated struct TypeScriptPluginSessionTranscript: Codable, Sendable, Equatable {
    let sessionID: String?
    let title: String?
    let entries: [TypeScriptPluginTranscriptEntry]
    let updatedAt: Date

    init(
        sessionID: String? = nil,
        title: String? = nil,
        entries: [TypeScriptPluginTranscriptEntry],
        updatedAt: Date = .now
    ) {
        self.sessionID = sessionID
        self.title = title
        self.entries = entries
        self.updatedAt = updatedAt
    }

    /// Builds the plugin snapshot from the same immutable blocks rendered by
    /// the chat surface. The plugin receives a copy and can never mutate the
    /// live timeline through this API.
    init(
        sessionID: String? = nil,
        title: String? = nil,
        blocks: [ChatBlock],
        updatedAt: Date = .now
    ) {
        self.init(
            sessionID: sessionID,
            title: title,
            entries: blocks.map(TypeScriptPluginTranscriptEntry.init),
            updatedAt: updatedAt
        )
    }

    var jsonValue: PluginJSONValue {
        .object([
            "sessionID": sessionID.map(PluginJSONValue.string) ?? .null,
            "title": title.map(PluginJSONValue.string) ?? .null,
            "updatedAt": .string(Self.iso8601String(from: updatedAt)),
            "entries": .array(entries.map(\.jsonValue))
        ])
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

nonisolated struct TypeScriptPluginTranscriptEntry: Codable, Sendable, Equatable {
    let id: String
    let kind: String
    let text: String
    let createdAt: Date
    let model: String?
    let providerID: String?

    init(
        id: String,
        kind: String,
        text: String,
        createdAt: Date,
        model: String? = nil,
        providerID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.model = model
        self.providerID = providerID
    }

    init(_ block: ChatBlock) {
        self.init(
            id: block.id,
            kind: block.kind.rawValue,
            text: block.text,
            createdAt: block.createdAt,
            model: block.model,
            providerID: block.providerId
        )
    }

    var jsonValue: PluginJSONValue {
        .object([
            "id": .string(id),
            "kind": .string(kind),
            "text": .string(text),
            "createdAt": .string(Self.iso8601String(from: createdAt)),
            "model": model.map(PluginJSONValue.string) ?? .null,
            "providerID": providerID.map(PluginJSONValue.string) ?? .null
        ])
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
