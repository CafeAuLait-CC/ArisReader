import AppKit

/// The marquee drawn while a region is being selected.
///
/// It is a real `NSView` above the canvas so the dashed rectangle does not need a GPU texture
/// or a model round-trip: the pointer event itself updates the path, exactly like the live pen
/// preview. It never consumes a click; the canvas beneath owns every event.
public final class AIRegionMarqueeOverlayView: NSView {
    private let shape = CAShapeLayer()
    private let fill = CAShapeLayer()

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var isOpaque: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        fill.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        fill.strokeColor = nil
        layer?.addSublayer(fill)
        shape.fillColor = nil
        shape.strokeColor = NSColor.controlAccentColor.cgColor
        shape.lineWidth = 1.5
        shape.lineDashPattern = [5, 3]
        shape.lineJoin = .round
        layer?.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("AIRegionMarqueeOverlayView is programmatic") }

    public override func layout() {
        super.layout()
        fill.frame = bounds
        shape.frame = bounds
    }

    public func show(rect: CGRect?) {
        guard let rect, rect.width > 0.5, rect.height > 0.5 else {
            show(rects: [])
            return
        }
        show(rects: [rect])
    }

    /// Draws one marquee per display segment. A drag across a torn page is still one page-local
    /// rectangle; it is drawn as the top piece and the bottom piece, with the card's gap between
    /// them, rather than as one band over the card.
    public func show(rects: [CGRect]) {
        let visible = rects.filter { $0.width > 0.5 && $0.height > 0.5 }
        guard !visible.isEmpty else {
            fill.path = nil
            shape.path = nil
            return
        }
        let path = CGMutablePath()
        for rect in visible { path.addRect(rect) }
        fill.path = path
        shape.path = path
    }

    /// A separate call so the outline can be redrawn without touching the fill during a drag.
    public func update(_ rect: CGRect?) {
        show(rect: rect)
    }

    public func update(rects: [CGRect]) {
        show(rects: rects)
    }
}
