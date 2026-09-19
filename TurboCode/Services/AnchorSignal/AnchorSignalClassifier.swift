import Foundation
import CoreAI

nonisolated struct AnchorSignalConfiguration: Sendable {
    let modelURL: URL
    let tokenizerURL: URL
    let maximumTokenCount: Int

    /// Reject weak rankings so the active profile keeps its normal tool set.
    static let minimumConfidence = 0.8

    static var `default`: Self {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Work/Programmi/Anchorsignal/models/anchorsignal-small")
        return Self(
            modelURL: root.appendingPathComponent("TextEncoder.aimodel"),
            tokenizerURL: root.appendingPathComponent("tokenizer/tokenizer.json"),
            // The exported Core AI graph has a fixed [1, 512] input shape.
            maximumTokenCount: 512
        )
    }
}

/// Runs the optional local AnchorSignal encoder and returns a bounded routing
/// decision. Model loading is lazy so enabling the UI control does not add a
/// startup cost to ordinary TurboCode sessions.
actor AnchorSignalClassifier {
    private let configuration: AnchorSignalConfiguration
    private var model: AIModel?
    private var function: InferenceFunction?
    private var tokenizer: AnchorSignalTokenizer?
    private var packageEmbeddings: [DynamicToolPackage: [Float]] = [:]

    init(configuration: AnchorSignalConfiguration = .default) {
        self.configuration = configuration
    }

    func classify(
        prompt: String,
        allowedToolIDs: Set<ToolCapabilityID>
    ) async -> DynamicRoutingDecision {
        let started = ContinuousClock.now
        let candidates = DynamicToolPackageResolver.candidates(
            allowedToolIDs: allowedToolIDs
        )

        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return profileFallback(
                reason: "The request is empty.",
                started: started
            )
        }

        do {
            try await loadIfNeeded()
            let query = try await embed("query: \(prompt)")
            var scored: [(DynamicToolPackage, Double)] = []
            for package in candidates {
                let anchor = try await embedding(for: package)
                // Intent is ranked only by the encoder. Profile permissions
                // constrain tools independently of wording or similarity.
                scored.append((package, cosineSimilarity(query, anchor)))
            }
            let ordered = scored.sorted { $0.1 > $1.1 }
            guard let best = ordered.first else {
                return profileFallback(
                    reason: "AnchorSignal returned no candidate category.",
                    started: started
                )
            }
            let selected = best.0
            let topScore = best.1
            let secondScore = ordered.dropFirst().first?.1 ?? 0
            guard topScore >= AnchorSignalConfiguration.minimumConfidence else {
                return profileFallback(
                    reason: "Similarity \(topScore.formatted(.number.precision(.fractionLength(3)))) is below the minimum 0.800.",
                    started: started
                )
            }
            return decision(
                package: selected,
                allowedToolIDs: allowedToolIDs,
                topScore: topScore,
                margin: topScore - secondScore,
                source: .model,
                started: started
            )
        } catch {
            return profileFallback(
                reason: error.localizedDescription,
                started: started
            )
        }
    }

    private func loadIfNeeded() async throws {
        guard function == nil else { return }
        guard FileManager.default.fileExists(atPath: configuration.modelURL.path),
              FileManager.default.fileExists(atPath: configuration.tokenizerURL.path) else {
            throw AnchorSignalError.assetsUnavailable
        }
        let loadedModel = try await AIModel(
            contentsOf: configuration.modelURL,
            options: .default
        )
        guard let loadedFunction = try loadedModel.loadFunction(named: "main") else {
            throw AnchorSignalError.functionUnavailable
        }
        let loadedTokenizer = try AnchorSignalTokenizer(
            contentsOf: configuration.tokenizerURL,
            maximumTokenCount: configuration.maximumTokenCount
        )
        // Publish only a complete load; a tokenizer error must allow retry.
        model = loadedModel
        function = loadedFunction
        tokenizer = loadedTokenizer
    }

    private func embedding(for package: DynamicToolPackage) async throws -> [Float] {
        if let cached = packageEmbeddings[package] {
            return cached
        }
        // E5 recommends query: on both sides of semantic similarity tasks;
        // passage: is for asymmetric document retrieval. Keep this prefix in
        // English even when the request or category description is multilingual.
        let values = try await embed("query: \(package.classifierDescription)")
        // Subsequent turns embed only the query.
        packageEmbeddings[package] = values
        return values
    }

    private func embed(_ text: String) async throws -> [Float] {
        guard let function, let tokenizer else {
            throw AnchorSignalError.functionUnavailable
        }
        let tokenized = try tokenizer.encode(text)
        let ids = NDArray(scalars: tokenized.ids, shape: [1, tokenized.ids.count])
        let mask = NDArray(scalars: tokenized.attentionMask, shape: [1, tokenized.attentionMask.count])
        var outputs = try await function.run(
            inputs: ["input_ids": ids, "attention_mask": mask]
        )
        guard let output = outputs.remove("embedding")?.ndArray else {
            throw AnchorSignalError.invalidOutput
        }
        let count = output.shape.last ?? 0
        switch output.scalarType {
        case .float32:
            let view = output.view(as: Float.self)
            return view.withUnsafePointer { pointer, _, _ in
                Array(UnsafeBufferPointer(start: pointer, count: count))
            }
        case .float16:
            let view = output.view(as: Float16.self)
            return view.withUnsafePointer { pointer, _, _ in
                UnsafeBufferPointer(start: pointer, count: count).map(Float.init)
            }
        default:
            throw AnchorSignalError.invalidOutput
        }
    }

    private func decision(
        package: DynamicToolPackage,
        allowedToolIDs: Set<ToolCapabilityID>,
        topScore: Double,
        margin: Double,
        source: DynamicRoutingDecision.Source,
        started: ContinuousClock.Instant
    ) -> DynamicRoutingDecision {
        DynamicRoutingDecision(
            package: package,
            toolIDs: DynamicToolPackageResolver.effectiveToolIDs(
                for: package,
                allowedToolIDs: allowedToolIDs
            ),
            topScore: topScore,
            margin: margin,
            source: source,
            latencyMilliseconds: started.duration(to: .now).milliseconds
        )
    }

    private func profileFallback(
        reason: String,
        started: ContinuousClock.Instant
    ) -> DynamicRoutingDecision {
        // No package was classified. The runtime must rebuild through the
        // profile's normal defaults, including its explicit tool selections.
        DynamicRoutingDecision(
            package: nil,
            toolIDs: [],
            topScore: 0,
            margin: 0,
            source: .fallback,
            latencyMilliseconds: started.duration(to: .now).milliseconds,
            fallbackReason: reason
        )
    }

    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let lhsMagnitude = sqrt(dot(lhs, lhs))
        let rhsMagnitude = sqrt(dot(rhs, rhs))
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot(lhs, rhs) / (lhsMagnitude * rhsMagnitude)
    }

    private func dot(_ lhs: [Float], _ rhs: [Float]) -> Double {
        zip(lhs, rhs).reduce(into: 0.0) { result, pair in
            result += Double(pair.0) * Double(pair.1)
        }
    }
}

private nonisolated enum AnchorSignalError: LocalizedError {
    case assetsUnavailable
    case functionUnavailable
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .assetsUnavailable: "The AnchorSignal model or tokenizer was not found in Work/Programmi/Anchorsignal/models/anchorsignal-small."
        case .functionUnavailable: "The AnchorSignal encoder function could not be loaded."
        case .invalidOutput: "The AnchorSignal encoder returned an invalid embedding."
        }
    }
}

private nonisolated struct AnchorSignalTokenizer: Sendable {
    private nonisolated struct File: Decodable {
        let model: Model
    }

    private nonisolated struct Model: Decodable {
        let vocab: [Entry]
    }

    private nonisolated struct Entry: Decodable {
        let token: String
        let score: Double

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            token = try container.decode(String.self)
            score = try container.decode(Double.self)
        }
    }

    private nonisolated struct Piece: Sendable {
        let bytes: [UInt8]
        let id: Int32
        let score: Double
    }

    nonisolated struct Encoded: Sendable {
        let ids: [Int32]
        let attentionMask: [Int32]
    }

    private let candidatesByFirstByte: [UInt8: [Piece]]
    private let maximumTokenCount: Int

    nonisolated init(contentsOf url: URL, maximumTokenCount: Int) throws {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(File.self, from: data)
        var candidates: [UInt8: [Piece]] = [:]
        for (id, entry) in file.model.vocab.enumerated() {
            let bytes = Array(entry.token.utf8)
            guard let first = bytes.first,
                  entry.token != "<s>",
                  entry.token != "</s>",
                  entry.token != "<pad>",
                  entry.token != "<unk>" else { continue }
            candidates[first, default: []].append(
                Piece(bytes: bytes, id: Int32(id), score: entry.score)
            )
        }
        self.candidatesByFirstByte = candidates
        self.maximumTokenCount = maximumTokenCount
    }

    nonisolated func encode(_ text: String) throws -> Encoded {
        let normalized = normalize(text)
        let bytes = Array(normalized.utf8)
        var scores = Array(repeating: -Double.infinity, count: bytes.count + 1)
        var paths = Array(repeating: [Int32](), count: bytes.count + 1)
        scores[0] = 0

        for position in 0..<bytes.count where scores[position].isFinite {
            var matched = false
            for piece in candidatesByFirstByte[bytes[position], default: []] {
                guard position + piece.bytes.count <= bytes.count,
                      Array(bytes[position..<(position + piece.bytes.count)]) == piece.bytes else {
                    continue
                }
                matched = true
                let next = position + piece.bytes.count
                let score = scores[position] + piece.score
                if score > scores[next] {
                    scores[next] = score
                    paths[next] = paths[position] + [piece.id]
                }
            }
            if !matched {
                let length = scalarByteLength(at: position, bytes: bytes)
                let next = min(bytes.count, position + length)
                if scores[position] - 100 > scores[next] {
                    scores[next] = scores[position] - 100
                    paths[next] = paths[position] + [3]
                }
            }
        }

        var ids = [Int32(0)] + paths[bytes.count] + [Int32(2)]
        if ids.count > maximumTokenCount {
            ids = Array(ids.prefix(maximumTokenCount - 1)) + [Int32(2)]
        }
        let mask = Array(repeating: Int32(1), count: ids.count)
        let padding = Array(repeating: Int32(1), count: max(0, maximumTokenCount - ids.count))
        return Encoded(
            ids: ids + padding,
            attentionMask: mask + Array(repeating: Int32(0), count: padding.count)
        )
    }

    private nonisolated func normalize(_ text: String) -> String {
        let canonical = text.precomposedStringWithCanonicalMapping
        let collapsed = canonical.reduce(into: "") { result, character in
            if character.isWhitespace {
                if result.last != " " { result.append(" ") }
            } else {
                result.append(character)
            }
        }
        let metaspace = collapsed.replacingOccurrences(of: " ", with: "▁")
        return metaspace.hasPrefix("▁") ? metaspace : "▁" + metaspace
    }

    private nonisolated func scalarByteLength(at position: Int, bytes: [UInt8]) -> Int {
        let byte = bytes[position]
        if byte < 0x80 { return 1 }
        if byte < 0xE0 { return 2 }
        if byte < 0xF0 { return 3 }
        return 4
    }
}

private extension Duration {
    nonisolated var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
