import SwiftUI
import AppKit

/// AppKit supplies the editable text surface while SwiftUI owns the draft and
/// the surrounding chrome. Programmatic updates preserve selection and scroll.
struct EditorialCanvasTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var verticalScrollOffset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, verticalScrollOffset: $verticalScrollOffset)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.usesFindPanel = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrollView(scrollView)
        resizeDocumentView(scrollView, textView: textView)
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let selection = textView.selectedRanges
        let scrollOrigin = scrollView.contentView.bounds.origin
        if textView.string != text {
            textView.string = text
            textView.selectedRanges = context.coordinator.clampedSelections(
                selection,
                for: textView.string.utf16.count
            )
        }
        resizeDocumentView(scrollView, textView: textView)
        context.coordinator.restoreScrollOrigin(scrollOrigin, in: scrollView)
    }

    /// AppKit does not always expand an NSTextView's document frame after a
    /// large paste when SwiftUI owns the surrounding viewport.
    private func resizeDocumentView(_ scrollView: NSScrollView, textView: NSTextView) {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }

        let width = max(scrollView.contentView.bounds.width, 1)
        textContainer.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)

        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let insetHeight = textView.textContainerInset.height * 2
        let height = max(usedHeight + insetHeight, scrollView.contentView.bounds.height)
        textView.setFrameSize(NSSize(width: width, height: height))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        private var verticalScrollOffset: Binding<CGFloat>
        private weak var observedClipView: NSClipView?

        init(text: Binding<String>, verticalScrollOffset: Binding<CGFloat>) {
            self.text = text
            self.verticalScrollOffset = verticalScrollOffset
        }

        func observeScrollView(_ scrollView: NSScrollView) {
            guard observedClipView == nil else { return }
            let clipView = scrollView.contentView
            observedClipView = clipView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        func stopObserving() {
            guard let observedClipView else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
            self.observedClipView = nil
        }

        @objc
        private func scrollViewBoundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView else { return }
            verticalScrollOffset.wrappedValue = clipView.bounds.origin.y
        }

        func clampedSelections(_ selections: [NSValue], for length: Int) -> [NSValue] {
            selections.map { value in
                let range = value.rangeValue
                let location = min(max(range.location, 0), length)
                let availableLength = max(0, length - location)
                let selectionLength = min(max(range.length, 0), availableLength)
                return NSValue(range: NSRange(location: location, length: selectionLength))
            }
        }

        func restoreScrollOrigin(_ origin: NSPoint, in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let maxY = max(
                0,
                documentView.frame.height - scrollView.contentView.bounds.height
            )
            let restoredOrigin = NSPoint(x: origin.x, y: min(max(origin.y, 0), maxY))
            scrollView.contentView.scroll(to: restoredOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
