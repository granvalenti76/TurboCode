import Foundation
import FoundationModels

/// Compact native-tool output returned to Foundation Models.
///
/// The model receives only the useful textual result and an opaque correlation
/// token. Potentially large application artifacts stay in the receipt registry
/// and therefore never inflate the model transcript.
@Generable
nonisolated struct ToolCommandOutput: Sendable, Equatable,
    ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    var text: String
    var receiptToken: String?

    init(text: String, receiptToken: String? = nil) {
        self.text = text
        self.receiptToken = receiptToken
    }

    init(stringLiteral value: String) {
        self.init(text: value)
    }

    init(stringInterpolation: DefaultStringInterpolation) {
        self.init(text: String(stringInterpolation: stringInterpolation))
    }

    static func plain(_ text: String) -> Self {
        Self(text: text)
    }

    static func recording(
        _ receipt: ToolReceipt?,
        text: String,
        in registry: ToolReceiptRegistry?
    ) async -> Self {
        guard let receipt, let registry else { return .plain(text) }
        return Self(text: text, receiptToken: await registry.store(receipt))
    }

    /// Wrapper tools may refine their user-facing completion text without
    /// breaking the opaque correlation established by the underlying editor.
    func replacingText(with text: String) -> Self {
        Self(text: text, receiptToken: receiptToken)
    }

    func hasPrefix(_ prefix: String) -> Bool {
        text.hasPrefix(prefix)
    }

    func contains(_ value: String) -> Bool {
        text.contains(value)
    }
}

/// Bridges the existing string-based approval gate without placing receipt
/// metadata in the approval text. The suspended tool consumes the typed output
/// after the approved action completes.
actor ToolCommandOutputRelay {
    private var output: ToolCommandOutput?

    func store(_ output: ToolCommandOutput) {
        self.output = output
    }

    func take() -> ToolCommandOutput? {
        defer { output = nil }
        return output
    }
}

/// One-shot correlation storage between a native tool and its completion event.
///
/// The registry is intentionally bounded: an abandoned provider callback must
/// not retain diff or Git artifacts for the lifetime of the application.
actor ToolReceiptRegistry {
    private let capacity: Int
    private var insertionOrder: [String] = []
    private var receipts: [String: ToolReceipt] = [:]

    init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    func store(_ receipt: ToolReceipt) -> String {
        while insertionOrder.count >= capacity, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            receipts.removeValue(forKey: oldest)
        }

        let token = UUID().uuidString
        insertionOrder.append(token)
        receipts[token] = receipt
        return token
    }

    /// Consuming rather than reading prevents duplicate provider completions
    /// from projecting the same application artifact more than once.
    func take(_ token: String) -> ToolReceipt? {
        insertionOrder.removeAll { $0 == token }
        return receipts.removeValue(forKey: token)
    }

    var storedReceiptCount: Int {
        receipts.count
    }
}
