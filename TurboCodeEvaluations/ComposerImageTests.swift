import CoreGraphics
import Foundation
import FoundationModels
import FoundationModelsUtilities
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TurboCode

@Suite("Composer image attachments")
struct ComposerImageTests {
    // MARK: Vision configuration

    @Test("An absent supportsVision stays unset so the server is asked")
    func absentVisionFlagDecodesAsUnset() throws {
        let absent = try decodeModel(extra: "")
        let declared = try decodeModel(extra: #","supportsVision":true"#)

        #expect(absent.supportsVision == nil)
        #expect(declared.supportsVision == true)
    }

    @Test("Only an explicit false removes the declared vision capability")
    func explicitFalseRemovesVisionCapability() {
        func capabilities(_ value: Bool?) -> LanguageModelCapabilities {
            ProviderLanguageModel(configuration: makeModel(supportsVision: value)).capabilities
        }

        #expect(capabilities(nil).contains(.vision))
        #expect(capabilities(true).contains(.vision))
        #expect(!capabilities(false).contains(.vision))
        #expect(capabilities(false).contains(.toolCalling))
    }

    @Test("Server props report vision only when the modality is true")
    func propsParsingRequiresVisionModality() {
        #expect(LlamaServerRuntimeProbe.supportsVision(inProps: ["modalities": ["vision": true]]))
        #expect(!LlamaServerRuntimeProbe.supportsVision(inProps: ["modalities": ["vision": false]]))
        #expect(!LlamaServerRuntimeProbe.supportsVision(inProps: ["modalities": ["audio": true]]))
        #expect(!LlamaServerRuntimeProbe.supportsVision(inProps: [:]))
    }

    // MARK: Vision admission

    @Test("A declared llama value wins and the server is not probed")
    func declaredValueSkipsProbe() async {
        let refused = await resolve(.llamaServer, model: makeModel(supportsVision: false), probe: true)
        let accepted = await resolve(.llamaServer, model: makeModel(supportsVision: true), probe: false)

        #expect(!refused)
        #expect(accepted)
    }

    @Test("An unset llama value follows the server probe")
    func unsetValueFollowsProbe() async {
        let accepted = await resolve(.llamaServer, model: makeModel(supportsVision: nil), probe: true)
        let refused = await resolve(.llamaServer, model: makeModel(supportsVision: nil), probe: false)

        #expect(accepted)
        #expect(!refused)
    }

    @Test("Apple on-device follows the system model capability")
    func onDeviceFollowsSystemCapability() async {
        let accepted = await resolve(.foundationApple, model: nil, probe: false, system: true)
        let refused = await resolve(.foundationApple, model: nil, probe: true, system: false)

        #expect(accepted)
        #expect(!refused)
    }

    @Test("Backends outside image input never accept images")
    func unsupportedRoutesAreRefused() async {
        let model = makeModel(supportsVision: true)
        let codex = await resolve(.codex, model: model, probe: true, system: true)
        let premium = await resolve(.premium, model: model, probe: true, system: true)

        #expect(!codex)
        #expect(!premium)
    }

    /// Image input stays independent of VM services: an image travels in the
    /// model prompt, so this adapter must never reach the Cowork runtime.
    @Test("Image handling source has no dependency on the Cowork VM")
    func imageHandlingStaysOutsideTheVM() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TurboCode/Models/ComposerImageAttachment.swift"),
            encoding: .utf8
        )
        for forbidden in ["CoworkVMRuntime", "import Containerization", "VMFileTool", "VMExecTool"] {
            #expect(!source.contains(forbidden))
        }
    }

    // MARK: Loading

    @Test("Large images are bounded and small images are not enlarged")
    func modelImageIsBoundedWithoutUpscaling() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let large = try ComposerImageLoader.load(
            from: writeImage(width: 3_000, height: 1_000, in: directory)
        )
        let small = try ComposerImageLoader.load(
            from: writeImage(width: 200, height: 100, in: directory)
        )

        #expect(try pixelSize(of: large.modelJPEGData) == CGSize(width: 1_568, height: 523))
        #expect(try pixelSize(of: small.modelJPEGData) == CGSize(width: 200, height: 100))
        #expect(try pixelSize(of: large.thumbnailJPEGData).width == 160)
    }

    @Test("Transparent pixels flatten onto white rather than black")
    func transparencyFlattensToWhite() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let attachment = try ComposerImageLoader.load(
            from: writeImage(width: 32, height: 32, alpha: 0, in: directory)
        )
        let source = try #require(CGImageSourceCreateWithData(attachment.modelJPEGData as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = try #require(image.dataProvider?.data as Data?)

        #expect(bytes[0] > 250)
    }

    @Test("Non-images and oversized files are rejected with distinct errors")
    func invalidFilesAreRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: text)
        let image = try writeImage(width: 64, height: 64, in: directory)

        #expect(throws: ComposerImageLoader.LoadError.notAnImage) {
            try ComposerImageLoader.load(from: text)
        }
        #expect(throws: ComposerImageLoader.LoadError.tooLarge) {
            try ComposerImageLoader.load(from: image, maxSourceByteCount: 1)
        }
    }

    // MARK: Intake

    @Test("Dropping a non-image shows a notice without asking about vision")
    func nonImageDropSkipsVisionCheck() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: text)

        let outcome = await ComposerImageIntake.process(
            urls: [text],
            existingCount: 0,
            supportsVision: {
                Issue.record("A non-image drop must not probe the server")
                return true
            }
        )

        #expect(outcome.attachments.isEmpty)
        #expect(outcome.notice == ComposerImageNotice.notAnImage)
    }

    @Test("A model without vision adds nothing and shows the discreet notice")
    func visionlessModelRefusesDrop() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outcome = await ComposerImageIntake.process(
            urls: [try writeImage(width: 64, height: 64, in: directory)],
            existingCount: 0,
            supportsVision: { false }
        )

        #expect(outcome.attachments.isEmpty)
        #expect(outcome.notice == ComposerImageNotice.visionUnsupported)
    }

    @Test("Drops beyond the draft limit keep what fits and explain the rest")
    func dropRespectsAttachmentLimit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<3).map { _ in try writeImage(width: 64, height: 64, in: directory) }

        let outcome = await ComposerImageIntake.process(
            urls: urls,
            existingCount: ComposerImagePolicy.maxAttachmentCount - 1,
            supportsVision: { true }
        )

        #expect(outcome.attachments.count == 1)
        #expect(outcome.notice == ComposerImageNotice.tooManyImages)
    }

    // MARK: Draft

    @Test("Clearing the text keeps images and taking them empties the draft")
    @MainActor
    func draftImagesOutliveTextReset() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let composer = ComposerViewModel()
        composer.messageText = "steering text"
        composer.addImages([try ComposerImageLoader.load(from: writeImage(width: 64, height: 64, in: directory))])

        composer.reset()
        #expect(composer.messageText.isEmpty)
        #expect(composer.imageAttachments.count == 1)

        #expect(composer.takeImages().count == 1)
        #expect(composer.imageAttachments.isEmpty)
    }

    // MARK: History marker

    @Test("The image marker is stored in the text and hidden beside live thumbnails")
    func referenceRoundTrip() {
        let stored = ChatImageReference.appending(fileNames: ["a.png", "b.png"], to: "Look")

        #expect(stored == "Look\n\n[Image: a.png]\n[Image: b.png]")
        #expect(ChatImageReference.removing(fileNames: ["a.png", "b.png"], from: stored) == "Look")
        // After a reload there are no thumbnails, so the marker stays visible.
        #expect(ChatImageReference.removing(fileNames: [], from: stored) == stored)
    }

    @Test("The sent user block keeps thumbnails while its stored text names the file")
    @MainActor
    func timelineRecordsThumbnailAndMarker() {
        let timeline = ChatTimelineStore()
        let thumbnail = ChatImageThumbnail(id: UUID(), fileName: "shot.png", jpegData: Data([1]))

        timeline.beginResponse(
            displayText: "Look",
            imageThumbnails: [thumbnail],
            placeholderID: "placeholder",
            model: "model"
        )

        let block = timeline.blocks.first { $0.kind == .user }
        #expect(block?.text == "Look\n\n[Image: shot.png]")
        #expect(block?.imageThumbnails == [thumbnail])
    }

    // MARK: Wire format

    @Test("An image prompt reaches the server as a JPEG data URL beside the text")
    func wireRequestCarriesImage() async throws {
        let (session, body) = try await sendImagePrompt()
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        let imageURL = content.compactMap { $0["image_url"] as? [String: Any] }.first?["url"] as? String

        #expect(content.compactMap { $0["text"] as? String }.joined().contains("What is this?"))
        #expect(imageURL?.hasPrefix("data:image/jpeg;base64,") == true)
        _ = session
    }

    @Test("Rebuilt history drops image data, keeps the text, and preserves entry identity")
    func rebuildReplacesImageAttachments() async throws {
        let (session, _) = try await sendImagePrompt()
        let original = session.transcript.compactMap { entry -> Transcript.Prompt? in
            if case .prompt(let prompt) = entry { return prompt }
            return nil
        }.first
        let originalPrompt = try #require(original)
        #expect(originalPrompt.segments.contains { if case .attachment = $0 { true } else { false } })

        let rebuilt = SessionRebuildHistory.prepare(
            session.transcript,
            keepingHistory: true,
            discardingCapabilityContext: false
        )
        let prompt = rebuilt.compactMap { entry -> Transcript.Prompt? in
            if case .prompt(let prompt) = entry { return prompt }
            return nil
        }.first
        let rebuiltPrompt = try #require(prompt)

        #expect(rebuiltPrompt.id == originalPrompt.id)
        #expect(!rebuiltPrompt.segments.contains { if case .attachment = $0 { true } else { false } })
        let text = rebuiltPrompt.segments.compactMap { segment -> String? in
            if case .text(let text) = segment { return text.content }
            return nil
        }.joined()
        #expect(text.contains("What is this?"))
        #expect(text.contains("[Image no longer available]"))
    }

    // MARK: Helpers

    private func resolve(
        _ backend: ModelBackend,
        model: RemoteModelConfig?,
        probe: Bool,
        system: Bool = false
    ) async -> Bool {
        await ModelVisionSupport.resolve(
            backend: backend,
            remoteModel: model,
            systemModelSupportsVision: { system },
            probeServer: { _ in probe }
        )
    }

    private func makeModel(supportsVision: Bool?) -> RemoteModelConfig {
        RemoteModelConfig(
            id: "vision-test",
            name: "Vision Test",
            url: "http://127.0.0.1:1/v1",
            modelName: "vision-test",
            temperature: 0.6,
            supportsVision: supportsVision
        )
    }

    private func decodeModel(extra: String) throws -> RemoteModelConfig {
        let json = #"{"id":"m","name":"M","url":"http://x/v1","modelName":"m""# + extra + "}"
        return try JSONDecoder().decode(RemoteModelConfig.self, from: Data(json.utf8))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComposerImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeImage(
        width: Int,
        height: Int,
        alpha: CGFloat = 1,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        let image = try #require(makeImage(width: width, height: height, alpha: alpha))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeImage(width: Int, height: Int, alpha: CGFloat) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(red: 0, green: 0, blue: 0, alpha: alpha)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    private func pixelSize(of data: Data) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }

    /// Runs the real transcript conversion and encoder against a captured URL
    /// loading boundary, so no external server is involved.
    private func sendImagePrompt() async throws -> (LanguageModelSession, [String: Any]) {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachment = try ComposerImageLoader.load(
            from: writeImage(width: 64, height: 64, in: directory)
        )
        let host = "image-wire-\(UUID().uuidString.lowercased()).invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageWireURLProtocol.self]
        let model = ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "https://\(host)")!,
            supportsGuidedGeneration: false,
            urlSessionConfiguration: configuration
        )
        let session = LanguageModelSession(model: model)

        _ = try await session.respond(
            to: ComposerImageAttachment.prompt(text: "What is this?", attachments: [attachment])
        )

        let captured = try #require(ImageWireURLProtocol.body(forHost: host))
        let body = try #require(try JSONSerialization.jsonObject(with: captured) as? [String: Any])
        return (session, body)
    }
}

/// Keyed by a per-test host because Swift Testing runs this suite in parallel.
private final class ImageWireURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Data] = [:]

    static func body(forHost host: String) -> Data? {
        lock.withLock { bodies[host] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasPrefix("image-wire-") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.bodyData(from: request)
        Self.lock.withLock { Self.bodies[host] = body }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        let stream = """
        data: {"id":"wire-response","model":"wire-model","choices":[{"delta":{"role":"assistant","content":"ok"}}]}

        data: [DONE]

        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
