import AppKit
import SwiftUI

// MARK: - Page-block pasteboard payload

extension NSPasteboard.PasteboardType {
    /// The private drag type for a block of thumbnail pages. The strip is the only producer and
    /// the only consumer; a drag that leaves the app is refused by the source's operation mask.
    static let lyraPageBlock = NSPasteboard.PasteboardType("com.aristreader.page-block")
}

/// What the source view puts on the pasteboard: the block, the page it was grabbed on, and enough
/// document identity for a drop target to refuse a block that belongs to another document.
struct ThumbnailDragPayload: Codable, Equatable, Sendable {
    let pages: [Int]
    let pressedPage: Int
    let documentPath: String
    let pageCount: Int
}

/// The identity a drop target checks before accepting a payload.
struct ThumbnailDragIdentity: Equatable, Sendable {
    let path: String
    let pageCount: Int
}

/// Collects each visible thumbnail cell's frame in the strip's coordinate space.
struct ThumbnailCellFramesKey: PreferenceKey {
    static let defaultValue: [ThumbnailCellFrame] = []

    static func reduce(
        value: inout [ThumbnailCellFrame],
        nextValue: () -> [ThumbnailCellFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - SwiftUI bridge

/// The AppKit drag source and drop destination laid over the thumbnail grid.
///
/// It is deliberately one AppKit view for the whole grid rather than one per thumbnail: a
/// `Button`'s click gesture and SwiftUI's `.onDrag` compete for the same pixels on macOS (adding
/// `.onDrag` to a sidebar row is known to stop its click), so the strip needs one owner of the
/// pointer that can decide between "this is still a click" and "this has become a drag" itself.
/// The AppKit view draws the insertion line directly, which also gives the drag session the
/// native image and the scroll view's real geometry for autoscroll.
struct ThumbnailDragOverlay: NSViewRepresentable {
    let pageCount: Int
    let frames: [Int: CGRect]
    let dragBlock: @MainActor (Int) -> ThumbnailDragBlockResolution
    let payloadIdentity: @MainActor () -> ThumbnailDragIdentity?
    let dragImage: @MainActor (Int, Int) -> NSImage?
    let onClick: @MainActor (Int, NSEvent.ModifierFlags) -> Void
    var onDoubleClick: (@MainActor (Int) -> Void)? = nil
    let onDrop: @MainActor (ThumbnailDropRequest) -> Void
    let onRefusal: @MainActor (ThumbnailDragRefusal) -> Void
    let menu: @MainActor (Int) -> NSMenu?

    func makeNSView(context: Context) -> ThumbnailDragHostView {
        let view = ThumbnailDragHostView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ThumbnailDragHostView, context: Context) {
        configure(view)
    }

    private func configure(_ view: ThumbnailDragHostView) {
        view.pageCount = pageCount
        view.frames = frames
        view.dragBlock = dragBlock
        view.payloadIdentity = payloadIdentity
        view.dragImage = dragImage
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDrop = onDrop
        view.onRefusal = onRefusal
        view.menuProvider = menu
    }
}

// MARK: - AppKit view

/// Owns the press/drag decision for the strip and the insertion indicator.
///
/// A press records its page and origin. Moving less than ``ThumbnailDrag/thresholdPt`` leaves it
/// a click, and releasing calls the same ``AppState/handleThumbnailClick(_:modifiers:)`` the
/// button used before drag support existed. Moving past the threshold starts an AppKit drag
/// session whose image is the page (or a stack of pages) being moved.
@MainActor
final class ThumbnailDragHostView: NSView, NSDraggingSource {
    var pageCount = 0
    var frames: [Int: CGRect] = [:]
    var dragBlock: (Int) -> ThumbnailDragBlockResolution = { _ in .refused(.noDocument) }
    var payloadIdentity: () -> ThumbnailDragIdentity?
    var dragImage: (Int, Int) -> NSImage?
    var onClick: (Int, NSEvent.ModifierFlags) -> Void
    var onDoubleClick: ((Int) -> Void)?
    var onDrop: (ThumbnailDropRequest) -> Void
    var onRefusal: (ThumbnailDragRefusal) -> Void
    var menuProvider: (Int) -> NSMenu?

    private var press: ThumbnailPressTracker?
    private var session: NSDraggingSession?
    private var payload: ThumbnailDragPayload?
    private var pending: ThumbnailDropResolution?
    private var indicator: CGRect?
    private var activeBlock: ThumbnailDragBlock?
    private var autoscrollTimer: Timer?

    /// Visible-edge distance at which a drag starts scrolling the strip.
    private static let autoscrollEdgePt: CGFloat = 28
    private static let autoscrollStepPt: CGFloat = 12

    init() {
        self.payloadIdentity = { nil }
        self.dragImage = { _, _ in nil }
        self.onClick = { _, _ in }
        self.onDrop = { _ in }
        self.onRefusal = { _ in }
        self.menuProvider = { _ in nil }
        super.init(frame: .zero)
        registerForDraggedTypes([.lyraPageBlock])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The drag image and the insertion line use the same top-left origin as the SwiftUI frames
    /// that `ThumbnailStripGeometry` consumes, so the AppKit view is flipped like SwiftUI.
    override var isFlipped: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelTracking()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Press and drag source

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(at: point) else {
            press = nil
            return
        }
        press = ThumbnailPressTracker(page: page, at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard var press else { return }
        let dragging = press.moved(to: point)
        self.press = press
        guard dragging else { return }
        // The press has become a drag: it must not also navigate on release.
        self.press = nil
        beginDrag(from: press.page, event: event, at: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let press else { return }
        self.press = nil
        guard press.isClick else { return }
        if event.clickCount >= 2, let onDoubleClick { onDoubleClick(press.page) }
        else { onClick(press.page, event.modifierFlags) }
    }

    private func beginDrag(from page: Int, event: NSEvent, at point: CGPoint) {
        guard session == nil else { return }
        let block: ThumbnailDragBlock
        switch dragBlock(page) {
        case .refused(let refusal):
            onRefusal(refusal)
            return
        case .block(let resolved):
            block = resolved
        }
        guard let identity = payloadIdentity(), identity.pageCount == pageCount else {
            onRefusal(.noDocument)
            return
        }
        let payload = ThumbnailDragPayload(
            pages: block.pages,
            pressedPage: block.pressedPage,
            documentPath: identity.path,
            pageCount: identity.pageCount
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: .lyraPageBlock)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = dragImage(block.pressedPage, block.count)
            ?? Self.fallbackDragImage(page: block.pressedPage, count: block.count)
        let frame = NSRect(
            x: point.x - image.size.width / 2,
            y: point.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        draggingItem.setDraggingFrame(frame, contents: image)
        self.payload = payload
        activeBlock = block
        let started = beginDraggingSession(with: [draggingItem], event: event, source: self)
        started.animatesToStartingPositionsOnCancelOrFail = true
        session = started
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Reordering stays inside one document and one app: do not offer pages to Finder.
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        cancelTracking()
    }

    // MARK: Drop destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        refuseDrop()
        stopAutoscroll()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pending?.request != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let operation = updateDrag(sender)
        guard operation == .move, let request = pending?.request else {
            refuseDrop()
            stopAutoscroll()
            return false
        }
        pending = nil
        clearIndicator()
        stopAutoscroll()
        activeBlock = nil
        payload = nil
        onDrop(request)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        refuseDrop()
        stopAutoscroll()
    }

    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let incoming = payload(from: sender),
              let identity = payloadIdentity(),
              incoming.documentPath == identity.path,
              incoming.pageCount == identity.pageCount,
              incoming.pageCount == pageCount,
              let first = incoming.pages.first,
              let last = incoming.pages.last,
              first >= 0,
              last < pageCount,
              last - first + 1 == incoming.pages.count else {
            refuseDrop()
            stopAutoscroll()
            return []
        }
        let block = ThumbnailDragBlock(pages: incoming.pages, pressedPage: incoming.pressedPage)
        let point = convert(sender.draggingLocation, from: nil)
        let resolution = resolve(block: block, at: point)
        switch resolution {
        case .move:
            pending = resolution
            activeBlock = block
            updateIndicator(at: point)
            updateAutoscroll(at: point)
            return .move
        case .refused:
            refuseDrop()
            updateAutoscroll(at: point)
            return []
        }
    }

    private func resolve(block: ThumbnailDragBlock, at point: CGPoint) -> ThumbnailDropResolution {
        let geometry = ThumbnailStripGeometry(pageCount: pageCount, frames: frames, bounds: bounds)
        let boundary = geometry.insertionBoundary(at: point)
        return ThumbnailDrag.drop(block: block, boundary: boundary, pageCount: pageCount)
    }

    private func updateIndicator(at point: CGPoint) {
        let geometry = ThumbnailStripGeometry(pageCount: pageCount, frames: frames, bounds: bounds)
        guard case .move(let request) = pending,
              geometry.insertionBoundary(at: point) != nil else {
            indicator = nil
            needsDisplay = true
            return
        }
        // Draw at the request's own landing place: for a drop after the last page the boundary
        // is pageCount, which is where `ThumbnailDrag.drop` resolved it.
        let first = request.pages.first ?? 0
        let drawnBoundary = request.destination < first
            ? request.destination
            : request.destination + request.pages.count
        indicator = geometry.indicatorRect(for: drawnBoundary)
        needsDisplay = true
    }

    private func refuseDrop() {
        pending = nil
        clearIndicator()
    }

    private func clearIndicator() {
        guard indicator != nil else { return }
        indicator = nil
        needsDisplay = true
    }

    private func payload(from sender: NSDraggingInfo) -> ThumbnailDragPayload? {
        guard let data = sender.draggingPasteboard.data(forType: .lyraPageBlock) else {
            return nil
        }
        return try? JSONDecoder().decode(ThumbnailDragPayload.self, from: data)
    }

    // MARK: Autoscroll

    private func updateAutoscroll(at point: CGPoint) {
        guard enclosingScrollView != nil else {
            stopAutoscroll()
            return
        }
        let visible = visibleRect
        let nearEdge = point.y < visible.minY + Self.autoscrollEdgePt
            || point.y > visible.maxY - Self.autoscrollEdgePt
        if nearEdge {
            startAutoscroll()
        } else {
            stopAutoscroll()
        }
    }

    private func startAutoscroll() {
        guard autoscrollTimer == nil else { return }
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(autoscrollTick(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    @objc private func autoscrollTick(_ timer: Timer) {
        guard let block = activeBlock, let window else {
            stopAutoscroll()
            return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(windowPoint, from: nil)
        let visible = visibleRect
        var delta: CGFloat = 0
        if point.y < visible.minY + Self.autoscrollEdgePt {
            delta = -Self.autoscrollStepPt
        } else if point.y > visible.maxY - Self.autoscrollEdgePt {
            delta = Self.autoscrollStepPt
        }
        guard delta != 0, let scrollView = enclosingScrollView else {
            stopAutoscroll()
            return
        }
        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let maxOrigin = max(0, documentHeight - clipView.bounds.height)
        var origin = clipView.bounds.origin
        origin.y = min(max(origin.y + delta, 0), maxOrigin)
        if origin.y != clipView.bounds.origin.y {
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
            // The pointer did not move, but the content under it did: keep the line where the
            // drop would land now.
            let moved = convert(windowPoint, from: nil)
            let resolution = resolve(block: block, at: moved)
            pending = resolution
            updateIndicator(at: moved)
        }
    }

    // MARK: Drawing and menu

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let indicator else { return }
        let path = NSBezierPath(roundedRect: indicator, xRadius: 1.5, yRadius: 1.5)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.fill()
        path.stroke()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(at: point) else { return nil }
        guard let menu = menuProvider(page), let window else { return nil }
        LyraMenuPresenter.shared.show(menu: menu, at: window.convertPoint(toScreen: event.locationInWindow),
                                      in: window, owner: self)
        return nil
    }

    // MARK: Helpers

    private func page(at point: CGPoint) -> Int? {
        frames
            .filter { $0.key >= 0 && $0.key < pageCount && $0.value.contains(point) }
            .min { lhs, rhs in
                lhs.value.width * lhs.value.height < rhs.value.width * rhs.value.height
            }?
            .key
    }

    private func cancelTracking() {
        press = nil
        session = nil
        payload = nil
        activeBlock = nil
        refuseDrop()
        stopAutoscroll()
    }

    private static func fallbackDragImage(page: Int, count: Int) -> NSImage {
        let size = NSSize(width: 80, height: 106)
        return NSImage(size: size, flipped: true) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            NSColor.white.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            let label = (count > 1 ? "\(count) pages" : "Page \(page + 1)") as NSString
            label.draw(
                at: NSPoint(x: 6, y: rect.midY - 7),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            return true
        }
    }
}
