import AppKit
import WebKit

// MARK: - Shared page loading

/// How the app loads an HTML artifact from a session's outbox, in one place.
///
/// The page was written by a model, so it gets a plain web view: no script
/// bridge into the app, no persistent website data, and file access limited
/// to the session's outbox so sibling scripts, styles, and images still load.
/// Network access is left on, because generated pages commonly load libraries
/// and fonts from a CDN and the page can reach nothing on the Mac but this
/// folder.
///
/// The preview and the thumbnail renderer both go through here, so a
/// thumbnail can never open a wider path to the outbox than the preview has.
enum CoworkArtifactWebPage {
    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    static func load(_ fileURL: URL, outbox: URL, in webView: WKWebView) {
        webView.loadFileURL(fileURL, allowingReadAccessTo: outbox)
    }
}

// MARK: - Thumbnail renderer

/// Makes the thumbnail of an HTML artifact by rendering the page.
///
/// Quick Look does not run JavaScript, so a dark page or a single-page app
/// comes back as a black or white rectangle. This loads the page in a web view
/// that is never shown, with the preview's own configuration, and takes a
/// snapshot once it has settled.
///
/// Unlike the preview, this runs a page the user did not open, for every
/// session the library shows. Three limits keep that cheap and quiet: pages
/// render one at a time, because the Mac is often busy running a local model;
/// each result is cached until the file changes; and media cannot start
/// playing without a user action.
final class CoworkPageThumbnailRenderer {
    static let shared = CoworkPageThumbnailRenderer()

    /// Identifies one version of a file. An agent rewrites pages in place, so
    /// the path alone would keep serving the thumbnail of the old content.
    nonisolated struct Key: Hashable, Sendable {
        let path: String
        let size: Int
        let modified: Date?

        init(fileURL: URL) {
            // A URL remembers the resource values it already read, so a copy
            // of the same URL would keep reporting the size and date from
            // before the rewrite. Drop them and ask the file system again.
            var fresh = fileURL
            fresh.removeAllCachedResourceValues()
            let values = try? fresh.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            path = fileURL.standardizedFileURL.path
            size = values?.fileSize ?? -1
            modified = values?.contentModificationDate
        }
    }

    /// A desktop-sized viewport, so a responsive page shows its wide layout,
    /// in the 4:3 shape of a library card.
    private static let viewport = CGSize(width: 1200, height: 900)
    /// Enough for a library card at Retina scale.
    private static let thumbnailWidth: CGFloat = 600
    /// A page that is still loading after this long is captured as it is.
    private static let loadTimeout: Duration = .seconds(8)
    /// Charts and frameworks draw after the load event; give them a moment.
    private static let settleDelay: Duration = .milliseconds(700)
    private static let cacheLimit = 48

    private var cache: [Key: NSImage] = [:]
    private var cacheOrder: [Key] = []
    private var inFlight: [Key: Task<NSImage?, Never>] = [:]
    /// The most recently queued render; the next one waits for it.
    private var tail: Task<NSImage?, Never>?

    /// The rendered thumbnail of the page, or `nil` when it cannot be loaded.
    ///
    /// The render is not tied to the caller: a card that scrolls away does not
    /// cancel it, so the result is ready when the card comes back.
    func thumbnail(for fileURL: URL, outbox: URL) async -> NSImage? {
        let key = Key(fileURL: fileURL)
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let previous = tail
        let task = Task<NSImage?, Never> {
            _ = await previous?.value
            return await Self.render(fileURL, outbox: outbox)
        }
        inFlight[key] = task
        tail = task

        let image = await task.value
        inFlight[key] = nil
        if let image { store(image, for: key) }
        return image
    }

    private func store(_ image: NSImage, for key: Key) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = image
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private static func render(_ fileURL: URL, outbox: URL) async -> NSImage? {
        let configuration = CoworkArtifactWebPage.configuration()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: configuration)
        let loading = PageLoad()
        webView.navigationDelegate = loading
        CoworkArtifactWebPage.load(fileURL, outbox: outbox, in: webView)

        guard await loading.wait(timeout: loadTimeout) else { return nil }
        try? await Task.sleep(for: settleDelay)

        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = CGRect(origin: .zero, size: viewport)
        snapshot.snapshotWidth = NSNumber(value: Double(thumbnailWidth))
        return try? await webView.takeSnapshot(configuration: snapshot)
    }
}

/// Waits for one page load. A failed load has nothing worth a thumbnail; a
/// load that only times out (a slow CDN, a page that keeps fetching) is still
/// captured, because a partly drawn page says more than a symbol.
private final class PageLoad: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var outcome: Bool?

    func wait(timeout: Duration) async -> Bool {
        if let outcome { return outcome }
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.finish(true)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation = $0 }
    }

    private func finish(_ canCapture: Bool) {
        guard outcome == nil else { return }
        outcome = canCapture
        continuation?.resume(returning: canCapture)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(false)
    }
}
