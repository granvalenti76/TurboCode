import CoreGraphics
import Foundation
import FoundationModels
import FoundationModelsUtilities
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TurboCode

@Suite("Cowork image viewing")
struct CoworkImageViewTests {
    // MARK: Format gate

    @Test("Only PNG, JPEG, GIF, and WebP signatures are recognized")
    func signaturesSelectTheAcceptedFormats() {
        #expect(CoworkImageFormat(signatureOf: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])) == .png)
        #expect(CoworkImageFormat(signatureOf: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(CoworkImageFormat(signatureOf: Data("GIF89a....".utf8)) == .gif)
        #expect(CoworkImageFormat(signatureOf: Data("RIFF\u{1}\u{2}\u{3}\u{4}WEBPVP8 ".utf8)) == .webP)
        // Formats ImageIO could decode but the tool deliberately keeps away from it.
        #expect(CoworkImageFormat(signatureOf: Data([0x49, 0x49, 0x2A, 0x00, 0, 0, 0, 0])) == nil)
        #expect(CoworkImageFormat(signatureOf: Data("<svg xmlns=".utf8)) == nil)
        #expect(CoworkImageFormat(signatureOf: Data("RIFF\u{1}\u{2}\u{3}\u{4}WAVEfmt ".utf8)) == nil)
        #expect(CoworkImageFormat(signatureOf: Data()) == nil)
    }

    // MARK: Tool behavior

    @Test("A model without vision gets a text answer and the VM is never touched")
    func visionlessModelNeverReachesTheVM() async throws {
        let runtime = BinaryRuntime(stdout: try Self.pngData(width: 32, height: 32))
        let tool = VMViewImageTool(context: Self.context(runtime: runtime)) { false }

        let outcome = await tool.view(arguments: VMViewImageArguments(path: "/out/page.png"))

        guard case .message(let text) = outcome else {
            Issue.record("Expected a text refusal")
            return
        }
        #expect(text.contains("cannot see images"))
        #expect(await runtime.startCount == 0)
        #expect(await runtime.requests.isEmpty)
    }

    @Test("An image in the VM is read as the agent with a bounded, quoted command and normalized")
    func imageIsReadBoundedAndNormalized() async throws {
        let runtime = BinaryRuntime(stdout: try Self.pngData(width: 3_000, height: 1_500))
        let tool = VMViewImageTool(context: Self.context(runtime: runtime)) { true }

        let outcome = await tool.view(arguments: VMViewImageArguments(path: "shots/it's.png"))

        guard case .image(let text, let attachment) = outcome else {
            Issue.record("Expected an image, got \(outcome)")
            return
        }
        #expect(text == "Image /home/cowork/sessions/session-1/shots/it's.png:")
        #expect(attachment.fileName == "it's.png")
        #expect(CoworkImageFormat(signatureOf: attachment.modelJPEGData) == .jpeg)
        let size = try Self.pixelSize(of: attachment.modelJPEGData)
        #expect(max(size.width, size.height) == CGFloat(ComposerImagePolicy.maxModelPixelEdge))

        let request = try #require(await runtime.requests.first)
        #expect(request.user == .agent)
        #expect(request.script.contains("head -c \(VMViewImageTool.maximumSourceBytes + 1) -- '/home/cowork/sessions/session-1/shots/it'\\''s.png'"))
    }

    @Test("A file over the limit is refused without being decoded")
    func oversizedFileIsRefused() async throws {
        var data = try Self.pngData(width: 8, height: 8)
        data.append(Data(count: VMViewImageTool.maximumSourceBytes + 1 - data.count))
        let tool = VMViewImageTool(context: Self.context(runtime: BinaryRuntime(stdout: data))) { true }

        let outcome = await tool.view(arguments: VMViewImageArguments(path: "/out/huge.png"))

        #expect(outcome == .message("/out/huge.png is larger than 10 MB. Resize or convert it with vm_exec first."))
    }

    @Test("Bytes that are not an accepted image format never reach the decoder")
    func unacceptedFormatIsRefused() async throws {
        let runtime = BinaryRuntime(stdout: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8))
        let tool = VMViewImageTool(context: Self.context(runtime: runtime)) { true }

        let outcome = await tool.view(arguments: VMViewImageArguments(path: "/out/logo.svg"))

        #expect(outcome == .message("/out/logo.svg is not a PNG, JPEG, GIF, or WebP image. Convert it with vm_exec first."))
    }

    @Test("A recognized signature with a corrupt body is reported, not thrown")
    func corruptImageIsReported() async throws {
        let runtime = BinaryRuntime(stdout: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]))
        let tool = VMViewImageTool(context: Self.context(runtime: runtime)) { true }

        let outcome = await tool.view(arguments: VMViewImageArguments(path: "/out/broken.png"))

        #expect(outcome == .message("/out/broken.png could not be decoded as an image."))
    }

    @Test("A missing file is reported by path")
    func missingFileIsReported() async throws {
        let tool = VMViewImageTool(context: Self.context(runtime: BinaryRuntime(stdout: Data(), exitCode: 2))) { true }

        let outcome = await tool.view(arguments: VMViewImageArguments(path: "/out/none.png"))

        #expect(outcome == .message("Not a file: /out/none.png"))
    }

    // MARK: Boundary

    @Test("The tool reads the guest only through the session context and never the Mac")
    func toolSourceStaysInsideTheVMBoundary() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TurboCode/Tools/Cowork/VMViewImageTool.swift"),
            encoding: .utf8
        )
        #expect(source.contains("context.run("))
        for forbidden in ["FileManager", "URLSession", "contentsOf:", "write(to", "Process(", "BashTool", "ChatStore"] {
            #expect(!source.contains(forbidden), "VMViewImageTool must not use \(forbidden)")
        }
    }

    // MARK: Wire format

    @Test("The viewed image reaches the server as a JPEG data URL inside the tool message")
    func toolResultCarriesImageOnTheWire() async throws {
        let runtime = BinaryRuntime(stdout: try Self.pngData(width: 64, height: 64))
        let tool = VMViewImageTool(context: Self.context(runtime: runtime)) { true }
        let host = "tool-image-wire-\(UUID().uuidString.lowercased()).invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ToolImageWireURLProtocol.self]
        let model = ChatCompletionsLanguageModel(
            name: "wire-model",
            url: URL(string: "https://\(host)")!,
            supportsGuidedGeneration: false,
            urlSessionConfiguration: configuration
        )
        let session = LanguageModelSession(model: model, tools: [tool])

        _ = try await session.respond(to: "Look at /out/page.png")

        // The first request made the model call the tool; the second one
        // carries the tool's result back to the server.
        let bodies = ToolImageWireURLProtocol.bodies(forHost: host)
        #expect(bodies.count == 2)
        let lastBody = try #require(bodies.last)
        let body = try #require(try JSONSerialization.jsonObject(with: lastBody) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let toolMessage = try #require(messages.last { $0["role"] as? String == "tool" })
        #expect(toolMessage["tool_call_id"] as? String == "call_view")
        let content = try #require(toolMessage["content"] as? [[String: Any]])
        let imageURL = content.compactMap { $0["image_url"] as? [String: Any] }.first?["url"] as? String

        #expect(content.compactMap { $0["text"] as? String }.joined().contains("Image /out/page.png:"))
        #expect(imageURL?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    // MARK: Helpers

    static func context(runtime: BinaryRuntime) -> CoworkSessionContext {
        CoworkSessionContext(
            runtime: runtime,
            configuration: CoworkVMConfiguration(outbox: URL(fileURLWithPath: "/tmp/cowork-outbox")),
            sessionID: "session-1"
        )
    }

    static func pngData(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func pixelSize(of data: Data) throws -> CGSize {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }
}

/// Replies with fixed bytes. The shared `RecordingRuntime` takes a string, and
/// image bytes are not valid UTF-8.
actor BinaryRuntime: CoworkVMRuntime {
    private let stdout: Data
    private let exitCode: Int32
    private(set) var requests: [CoworkExecRequest] = []
    private(set) var startCount = 0
    private var running: CoworkVMConfiguration?

    init(stdout: Data, exitCode: Int32 = 0) {
        self.stdout = stdout
        self.exitCode = exitCode
    }

    func start(_ configuration: CoworkVMConfiguration) async throws {
        startCount += 1
        running = configuration
    }

    func exec(_ request: CoworkExecRequest) async throws -> AsyncThrowingStream<CoworkExecEvent, any Error> {
        requests.append(try request.validated())
        let output = stdout
        let code = exitCode
        return AsyncThrowingStream { continuation in
            if !output.isEmpty { continuation.yield(.stdout(output)) }
            continuation.yield(.exited(code))
            continuation.finish()
        }
    }

    func stop() async throws { running = nil }
    func reset() async throws { running = nil }
    func state() async -> CoworkVMState { running.map(CoworkVMState.running) ?? .stopped }
}

/// Answers the first request of a host with a `vm_view_image` call and every
/// later one with plain text, recording each request body. Keyed by a per-test
/// host because Swift Testing runs suites in parallel.
private final class ToolImageWireURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String: [Data]] = [:]

    static func bodies(forHost host: String) -> [Data] {
        lock.withLock { recorded[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasPrefix("tool-image-wire-") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.bodyData(from: request) ?? Data()
        let isFirst = Self.lock.withLock {
            Self.recorded[host, default: []].append(body)
            return Self.recorded[host]?.count == 1
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        let stream = isFirst
            ? """
            data: {"id":"wire-1","model":"wire-model","choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_view","type":"function","function":{"name":"vm_view_image","arguments":"{\\"path\\":\\"/out/page.png\\"}"}}]}}]}

            data: {"id":"wire-1","model":"wire-model","choices":[{"delta":{},"finish_reason":"tool_calls"}]}

            data: [DONE]


            """
            : """
            data: {"id":"wire-2","model":"wire-model","choices":[{"delta":{"role":"assistant","content":"ok"}}]}

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
