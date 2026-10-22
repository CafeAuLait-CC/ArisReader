import AppKit
import SwiftUI

/// AppKit owns horizontal overflow; AppState keeps vertical scrolling and the page band.
struct HorizontalDocumentViewport<Content: View>: NSViewRepresentable {
    let contentWidth: CGFloat
    let onViewport: (CGSize) -> Void
    let onHorizontalScroll: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> Viewport { Viewport(content: content()) }
    func updateNSView(_ view: Viewport, context: Context) {
        view.host.rootView = content()
        view.documentWidth = contentWidth
        view.onViewport = onViewport
        view.onHorizontalScroll = onHorizontalScroll
        view.needsLayout = true
    }

    final class Viewport: NSScrollView {
        let host: NSHostingView<Content>
        var documentWidth: CGFloat = 0
        var onViewport: ((CGSize) -> Void)?
        var onHorizontalScroll: ((CGFloat) -> Void)?
        nonisolated(unsafe) private var observer: NSObjectProtocol?
        private var reportedSize: CGSize = .zero
        private var reportedX: CGFloat = -1

        init(content: Content) {
            host = NSHostingView(rootView: content)
            host.sizingOptions = []
            super.init(frame: .zero)
            drawsBackground = false
            borderType = .noBorder
            hasVerticalScroller = false
            hasHorizontalScroller = true
            autohidesScrollers = true
            // Horizontal overflow must not change the page's height/top during a drawer
            // transition. The native overlay scroller occupies the bottom edge only.
            scrollerStyle = .overlay
            horizontalScrollElasticity = .none
            verticalScrollElasticity = .none
            documentView = host
            contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportViewport() }
            }
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        override func tile() {
            super.tile()
            // AppKit may retile for the user's scroller preference after a wheel event.
            // This viewport always overlays its horizontal control, so that change must
            // never remove a strip of page height or move the document vertically.
            if contentView.frame != bounds { contentView.frame = bounds }
        }

        override func layout() {
            super.layout()
            let size = contentSize
            let width = max(size.width, documentWidth)
            let target = CGSize(width: width, height: size.height)
            if host.frame.size != target { host.setFrameSize(target) }
            let x = min(max(0, contentView.bounds.minX), max(0, width - size.width))
            if contentView.bounds.minX != x {
                contentView.scroll(to: CGPoint(x: x, y: 0))
                reflectScrolledClipView(contentView)
            }
            reportViewport()
        }

        private func reportViewport() {
            let size = contentSize
            let x = contentView.bounds.minX
            guard size != reportedSize || x != reportedX else { return }
            reportedSize = size
            reportedX = x
            DispatchQueue.main.async { [weak self] in
                self?.onViewport?(size)
                self?.onHorizontalScroll?(x)
            }
        }
    }
}

struct ReaderEditingPanelTransition<Content: View>: View {
    static var width: CGFloat { 292 }
    let isVisible: Bool
    let progressOverride: Double?
    @ViewBuilder let content: () -> Content
    var body: some View {
        let progress = CGFloat(progressOverride.map { min(max($0, 0), 1) } ?? (isVisible ? 1 : 0))
        content()
            .frame(width: Self.width)
            .frame(width: Self.width * progress, alignment: .leading)
            .clipped()
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

struct DocumentEditedReporter: NSViewRepresentable {
    let isEdited: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in view?.window?.isDocumentEdited = isEdited }
    }
}
