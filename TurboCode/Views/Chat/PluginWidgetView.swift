import SwiftUI
import WebKit

/// Hosts one plugin-owned HTML surface inside the response timeline or a
/// detached window. Inline mode honors the plugin-reported height; detached
/// mode expands the WebView to the available window content area.
struct PluginWidgetView: View {
    @Environment(ChatStore.self) private var chatStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    let blockID: String
    let widget: TypeScriptPluginWidgetReceipt
    let isDetachedWindow: Bool

    @State private var height: CGFloat

    init(
        blockID: String,
        widget: TypeScriptPluginWidgetReceipt,
        isDetachedWindow: Bool = false
    ) {
        self.blockID = blockID
        self.widget = widget
        self.isDetachedWindow = isDetachedWindow
        // The inline surface keeps its existing compact default; the detached
        // window starts larger so a newly opened widget is immediately useful.
        _height = State(initialValue: isDetachedWindow ? 560 : 360)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(.secondary)
                Text(widget.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(widget.pluginID)/\(widget.widgetID)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help("This interactive surface is provided by the TypeScript plugin.")

                Button {
                    if isDetachedWindow {
                        restoreToTimeline()
                    } else {
                        detachToWindow()
                    }
                } label: {
                    Image(
                        systemName: isDetachedWindow
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isDetachedWindow ? "Rimetti nella chat" : "Apri in una finestra separata")
                .accessibilityLabel(isDetachedWindow ? "Rimetti nella chat" : "Apri in una finestra separata")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            widgetSurface
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeInOut(duration: 0.22), value: chatStore.isPluginWidgetDetached(blockID: blockID))
    }

    @ViewBuilder
    private var widgetSurface: some View {
        if isDetachedWindow {
            // A detached widget is a window-level surface, so its WebView
            // must consume the remaining height instead of retaining the
            // inline plugin resize value.
            PluginWidgetWebView(widget: widget, height: $height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else if !chatStore.isPluginWidgetDetached(blockID: blockID) {
            PluginWidgetWebView(widget: widget, height: $height)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            detachedPlaceholder
                .frame(height: height)
        }
    }

    private var detachedPlaceholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)

            VStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)

                Text("Widget aperto in una finestra separata")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Button {
                    restoreToTimeline()
                } label: {
                    Label("Rimetti nella chat", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func detachToWindow() {
        withAnimation(.easeInOut(duration: 0.22)) {
            chatStore.detachPluginWidget(widget, blockID: blockID)
        }
        openWindow(value: blockID)
    }

    private func restoreToTimeline() {
        withAnimation(.easeInOut(duration: 0.22)) {
            chatStore.restorePluginWidget(blockID: blockID)
        }
        // The main placeholder can also restore the widget while its
        // detached window is open; close that exact window as well.
        dismissWindow(id: "plugin-widget", value: blockID)
    }
}

private struct PluginWidgetWebView: NSViewRepresentable {
    let widget: TypeScriptPluginWidgetReceipt
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(widget: widget, height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(
                source: """
                window.turbocode = {
                  emit: function(message) {
                    window.webkit.messageHandlers.turbocode.postMessage(message);
                  },
                  resize: function(value) {
                    window.webkit.messageHandlers.turbocode.postMessage({type: 'resize', height: value});
                  },
                  setProps: function(value) {
                    window.dispatchEvent(new CustomEvent('turbocode-props', {detail: value}));
                  }
                };
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        contentController.add(context.coordinator, name: "turbocode")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(widget: widget, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(widget: widget, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "turbocode"
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var widget: TypeScriptPluginWidgetReceipt
        private var height: Binding<CGFloat>
        private var hasLoaded = false

        init(widget: TypeScriptPluginWidgetReceipt, height: Binding<CGFloat>) {
            self.widget = widget
            self.height = height
        }

        func load(widget: TypeScriptPluginWidgetReceipt, in webView: WKWebView) {
            self.widget = widget
            // Resolve the plugin root before handing it to WebKit. This keeps
            // bundled assets readable when the plugin directory was installed
            // through a symlink or another indirection.
            let root = URL(fileURLWithPath: widget.pluginRoot)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let entrypoint = root
                .appendingPathComponent(widget.entrypoint)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard FileManager.default.isReadableFile(atPath: entrypoint.path) else {
                showFailure("Widget entrypoint not found.", in: webView)
                return
            }
            webView.loadFileURL(entrypoint, allowingReadAccessTo: root)
        }

        func update(widget: TypeScriptPluginWidgetReceipt, in webView: WKWebView) {
            guard self.widget != widget else { return }
            self.widget = widget
            hasLoaded = false
            load(widget: widget, in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasLoaded = true
            sendProps(to: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            showFailure(error.localizedDescription, in: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            showFailure(error.localizedDescription, in: webView)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else { return }
            switch type {
            case "resize":
                guard let value = payload["height"] as? NSNumber else { return }
                height.wrappedValue = min(720, max(220, CGFloat(truncating: value)))
            case "ready":
                if let webView = message.webView {
                    sendProps(to: webView)
                }
            case "action":
                guard let action = payload["action"] as? String,
                      !action.isEmpty,
                      let webView = message.webView else { return }
                // Keep the first host round-trip deliberately small: the host
                // acknowledges receipt, while the plugin owns the resulting UI.
                sendHostEvent(
                    [
                        "type": "action",
                        "action": action,
                        "accepted": true,
                        "receivedAt": ISO8601DateFormatter().string(from: Date())
                    ],
                    to: webView
                )
            default:
                break
            }
        }

        private func sendHostEvent(_ event: [String: Any], to webView: WKWebView) {
            guard JSONSerialization.isValidJSONObject(event),
                  let data = try? JSONSerialization.data(withJSONObject: event),
                  let json = String(data: data, encoding: .utf8) else { return }
            let script = "window.dispatchEvent(new CustomEvent('turbocode-host-event', {detail: \(json)}));"
            webView.evaluateJavaScript(script)
        }

        private func showFailure(_ message: String, in webView: WKWebView) {
            hasLoaded = false
            let escapedMessage = message
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            webView.loadHTMLString(
                "<body style='font: -apple-system-body; padding: 16px'>Unable to load widget: \(escapedMessage)</body>",
                baseURL: nil
            )
        }

        private func sendProps(to webView: WKWebView) {
            guard hasLoaded,
                  let data = try? JSONEncoder().encode(widget.props),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.turbocode.setProps(\(json));")
        }
    }
}
