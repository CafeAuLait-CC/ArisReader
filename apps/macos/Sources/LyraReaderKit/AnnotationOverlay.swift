import AppKit
import CoreGraphics
import QuartzCore

/// The layer that draws the reader's ink, shapes and selection chrome **above** the Metal canvas.
///
/// Sticky-note icons and text boxes' text are bitmaps handed to the Metal canvas (see
/// `PlacementIndex.ownNote`); this layer draws their selection halo and the eight resize handles
/// of a selected text box, plus the live preview of a drag.
///
/// Two reasons this is not a texture like a highlight:
///
/// * A stroke is a vector path. Rasterising one into a page-sized bitmap would be re-done on
///   every zoom step and would show the same staircase at every scale; a `CAShapeLayer` draws
///   its path once in content coordinates and the compositor scales it.
/// * The live pen has to be updated from inside the pointer event. Calling AppState for every
///   sample and waiting for a SwiftUI pass adds a run-loop turn between the pointer and the ink;
///   the drag here goes straight into `liveLayer.path` and the display composites it on the next
///   frame, with no model write until mouse-up.
///
/// Coordinates: every path this view stores is in **content points** (page placement offset
/// applied, not zoomed). The container layer's affine transform converts content points to the
/// canvas' view points, so scrolling and zooming move the existing paths instead of rebuilding
/// them.
final class AnnotationOverlayView: NSView {
    private let container = CALayer()
    private let marksLayer = CALayer()
    private let redactionsLayer = CALayer()
    private let selectionLayer = CAShapeLayer()
    /// The same halo language as `selectionLayer`, drawn for the ink stroke an armed eraser is
    /// over. A separate layer so a selected mark and the eraser's target can both be visible.
    private let eraserTargetLayer = CAShapeLayer()
    private let liveLayer = CAShapeLayer()
    private var markLayers: [CALayer] = []

    /// Content points → page placement offset; the canvas supplies these with each model update.
    private var frames: [Int: PagePlacement] = [:]
    private var framesList: [PagePlacement] = []
    private var marks: [CanvasAnnotationMark] = []
    private var redactionMarks: [CanvasRedactionMark] = []
    private var redactionFrames: [Int: PagePlacement] = [:]
    private var zoom: CGFloat = 1
    private var scrollYPt: CGFloat = 0
    private var contentWidthPt: CGFloat = 0
    private var strokeColor = NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.15, alpha: 1)
    private var paperAppearance: PaperAppearance = .original
    private var strokeWidth: CGFloat = 2
    private var themeColor = NSColor.controlAccentColor

    /// Top-left origin, like every other coordinate in this file and in the canvas.
    ///
    /// `NSView` is bottom-left by default and a `CALayer` tree follows it unless told otherwise;
    /// without both flips the marks were mirrored vertically against the page (a stroke drawn
    /// near the top of page one appeared near the bottom).
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.addSublayer(container)
        container.addSublayer(marksLayer)
        container.addSublayer(redactionsLayer)
        container.addSublayer(selectionLayer)
        container.addSublayer(eraserTargetLayer)
        container.addSublayer(liveLayer)
        container.anchorPoint = CGPoint(x: 0, y: 0)
        container.position = .zero
        container.bounds = CGRect(origin: .zero, size: frameRect.size)
        selectionLayer.fillColor = nil
        selectionLayer.lineDashPattern = [NSNumber(value: 4), NSNumber(value: 3)]
        selectionLayer.lineCap = .butt
        eraserTargetLayer.fillColor = nil
        eraserTargetLayer.lineDashPattern = [NSNumber(value: 4), NSNumber(value: 3)]
        eraserTargetLayer.lineCap = .butt
        liveLayer.fillColor = nil
        liveLayer.lineJoin = .round
        liveLayer.lineCap = .round
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("AnnotationOverlayView is programmatic") }

    /// The overlay must never consume a click: every pointer event belongs to the canvas beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        container.bounds = CGRect(origin: .zero, size: bounds.size)
        updateTransform()
    }

    func update(
        marks: [CanvasAnnotationMark],
        frames: [PagePlacement],
        zoom: CGFloat,
        scrollYPt: CGFloat,
        contentWidthPt: CGFloat,
        color: NSColor,
        strokeWidth: CGFloat,
        themeColor: NSColor,
        paperAppearance: PaperAppearance = .original
    ) {
        let framesChanged = frames != framesList
        self.framesList = frames
        self.frames = Dictionary(uniqueKeysWithValues: frames.map { ($0.index, $0) })
        self.zoom = zoom
        self.scrollYPt = scrollYPt
        self.contentWidthPt = contentWidthPt
        let appearanceChanged = self.paperAppearance != paperAppearance
        self.paperAppearance = paperAppearance
        self.strokeColor = paperAppearance.displayColor(color)
        self.strokeWidth = strokeWidth
        self.themeColor = themeColor
        if marks != self.marks || framesChanged || appearanceChanged {
            self.marks = marks
            rebuildMarkLayers()
        }
        if framesChanged {
            self.redactionFrames = Dictionary(uniqueKeysWithValues: frames.map { ($0.index, $0) })
            rebuildRedactionLayers()
        }
        updateTransform()
    }

    /// Draws the redaction rectangles that are still pending.
    ///
    /// A pending mark is not an annotation: it is a warning that this area will be removed if
    /// the reader confirms. The fill is dark and the outline is dashed so it can never be
    /// mistaken for the finished black mark.
    func updateRedactions(_ marks: [CanvasRedactionMark], frames: [PagePlacement]) {
        let framesChanged = frames != framesList
        self.redactionFrames = Dictionary(uniqueKeysWithValues: frames.map { ($0.index, $0) })
        guard marks != redactionMarks || framesChanged else { return }
        self.redactionMarks = marks
        rebuildRedactionLayers()
    }

    private func rebuildRedactionLayers() {
        for layer in redactionsLayer.sublayers ?? [] {
            layer.removeFromSuperlayer()
        }
        for mark in redactionMarks {
            guard let frame = redactionFrames[mark.page] else { continue }
            let content = CGRect(
                x: frame.leftPt + mark.rect.minX,
                y: frame.topPt + mark.rect.minY,
                width: mark.rect.width,
                height: mark.rect.height
            )
            let fill = CAShapeLayer()
            fill.path = CGPath(rect: content, transform: nil)
            fill.fillColor = NSColor(calibratedWhite: 0.08, alpha: 0.55).cgColor
            fill.strokeColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
            fill.lineWidth = 1.2 / max(zoom, 0.01)
            fill.lineDashPattern = [4, 3]
            redactionsLayer.addSublayer(fill)
        }
    }

    /// The page-local points of the mark under a content point, or `nil`.
    ///
    /// This is the same `AnnotationGeometry.hitTest` the checks call; only editable marks are
    /// considered, because selecting a PDF's own ink would promise an edit this build cannot
    /// make. The tolerance is in view points, converted to content points by the zoom.
    func hitTestMark(atContentPoint point: CGPoint, toleranceViewPt: CGFloat) -> CanvasAnnotationMark? {
        let tolerance = toleranceViewPt / max(zoom, 0.01)
        for mark in marks.reversed() where mark.isEditable {
            guard let frame = frames[mark.page] else { continue }
            let local = CGPoint(x: point.x - frame.leftPt, y: point.y - frame.topPt)
            if AnnotationGeometry.hitTest(mark, at: local, tolerance: tolerance) { return mark }
        }
        return nil
    }

    /// Starts a live preview for a gesture in `page`.
    func beginLiveStroke(kind: AppState.Annotation.Kind, page: Int, at point: CGPoint) {
        guard let frame = frames[page] else { return }
        let content = CGPoint(x: frame.leftPt + point.x, y: frame.topPt + point.y)
        liveLayer.lineWidth = max(strokeWidth, 0.1)
        liveLayer.strokeColor = strokeColor.cgColor
        liveLayer.fillColor = kind == .arrow ? strokeColor.cgColor : nil
        liveLayer.lineJoin = .round
        liveLayer.lineCap = .round
        liveLayer.isHidden = false
        switch kind {
        case .line, .arrow:
            liveLayer.path = nil
            liveStart = content
            liveEnd = content
        case .ink:
            liveLayer.path = AnnotationGeometry.strokePath([content])
            livePoints = [content]
        case .square, .circle:
            liveLayer.path = nil
            liveStart = content
            liveEnd = content
        case .highlight, .underline, .strikeout, .stickyNote, .textBox:
            break
        }
        liveKind = kind
        livePage = page
    }

    func extendLiveStroke(atContentPoint content: CGPoint) {
        guard let kind = liveKind, let page = livePage, frames[page] != nil else { return }
        switch kind {
        case .ink:
            if let last = livePoints.last, hypot(content.x - last.x, content.y - last.y) < 0.4 {
                return
            }
            livePoints.append(content)
            liveLayer.path = AnnotationGeometry.strokePath(livePoints)
        case .line, .arrow:
            liveEnd = content
            liveLayer.path = lineOrArrowPath(kind: kind, start: liveStart, end: liveEnd,
                                             width: strokeWidth)
        case .square, .circle:
            liveEnd = content
            let rect = CGRect(x: min(liveStart.x, liveEnd.x), y: min(liveStart.y, liveEnd.y),
                              width: abs(liveEnd.x - liveStart.x),
                              height: abs(liveEnd.y - liveStart.y))
            let path = CGMutablePath()
            if kind == .square { path.addRect(rect) } else { path.addEllipse(in: rect) }
            liveLayer.path = path
        case .highlight, .underline, .strikeout, .stickyNote, .textBox:
            break
        }
    }

    /// Ends the preview. Returns the page-local draft only when the gesture described a mark.
    func finishLiveStroke(in frames: [PagePlacement]) -> AnnotationDraft? {
        defer {
            liveKind = nil
            livePage = nil
            liveLayer.path = nil
            livePoints = []
        }
        guard let kind = liveKind, let page = livePage,
              let frame = frames.first(where: { $0.index == page }) else { return nil }
        switch kind {
        case .ink:
            guard livePoints.count >= 2 else { return nil }
            let pagePoints = livePoints.map { CGPoint(x: $0.x - frame.leftPt, y: $0.y - frame.topPt) }
            return AnnotationDraft(kind: .ink, page: page, inkPaths: [pagePoints])
        case .line, .arrow:
            let start = CGPoint(x: liveStart.x - frame.leftPt, y: liveStart.y - frame.topPt)
            let end = CGPoint(x: liveEnd.x - frame.leftPt, y: liveEnd.y - frame.topPt)
            guard hypot(end.x - start.x, end.y - start.y) >= 1 else { return nil }
            return AnnotationDraft(kind: kind, page: page, lineStart: start, lineEnd: end)
        case .square, .circle:
            let start = CGPoint(x: liveStart.x - frame.leftPt, y: liveStart.y - frame.topPt)
            let end = CGPoint(x: liveEnd.x - frame.leftPt, y: liveEnd.y - frame.topPt)
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return AnnotationDraft(kind: kind, page: page, shapeRect: rect)
        case .highlight, .underline, .strikeout, .stickyNote, .textBox:
            return nil
        }
    }

    func cancelLiveStroke() {
        liveKind = nil
        livePage = nil
        liveLayer.path = nil
        livePoints = []
    }

    // MARK: - Live gesture state

    private var liveKind: AppState.Annotation.Kind?
    private var livePage: Int?
    private var livePoints: [CGPoint] = []
    private var liveStart: CGPoint = .zero
    private var liveEnd: CGPoint = .zero

    // MARK: - Committed marks

    private func rebuildMarkLayers() {
        for layer in markLayers { layer.removeFromSuperlayer() }
        markLayers = []
        selectionLayer.path = nil
        eraserTargetLayer.path = nil
        for mark in marks {
            guard let frame = frames[mark.page] else { continue }
            let layers = layers(for: mark, frame: frame)
            for layer in layers { marksLayer.addSublayer(layer) }
            markLayers.append(contentsOf: layers)
            if mark.isSelected {
                selectionLayer.path = haloPath(for: mark, frame: frame)
                selectionLayer.strokeColor = themeColor.withAlphaComponent(0.85).cgColor
                selectionLayer.lineWidth = 1 / max(zoom, 0.01)
                selectionLayer.lineDashPattern = [
                    NSNumber(value: 4 / max(zoom, 0.01)),
                    NSNumber(value: 3 / max(zoom, 0.01)),
                ]
                if mark.kind == .textBox {
                    appendResizeHandles(for: mark, frame: frame)
                }
            }
            if mark.isEraseTarget {
                // Exactly the select tool's halo: the eraser is showing what a press will
                // remove, not inventing a second visual language for "about to change".
                eraserTargetLayer.path = haloPath(for: mark, frame: frame)
                eraserTargetLayer.strokeColor = themeColor.withAlphaComponent(0.85).cgColor
                eraserTargetLayer.lineWidth = 1 / max(zoom, 0.01)
                eraserTargetLayer.lineDashPattern = [
                    NSNumber(value: 4 / max(zoom, 0.01)),
                    NSNumber(value: 3 / max(zoom, 0.01)),
                ]
            }
        }
    }

    private func layers(for mark: CanvasAnnotationMark, frame: PagePlacement) -> [CALayer] {
        let offset = CGPoint(x: frame.leftPt, y: frame.topPt)
        var paths: (stroke: CGPath, fill: CGPath?) = (CGMutablePath(), nil)
        switch mark.kind {
        case .ink:
            let path = CGMutablePath()
            for stroke in mark.inkPaths where !stroke.isEmpty {
                path.addPath(AnnotationGeometry.strokePath(stroke.map {
                    CGPoint(x: $0.x + offset.x, y: $0.y + offset.y)
                }))
            }
            paths.stroke = path
        case .square, .circle:
            let rect = (mark.shapeRect ?? .zero).offsetBy(dx: offset.x, dy: offset.y)
            let path = CGMutablePath()
            if mark.kind == .square { path.addRect(rect) } else { path.addEllipse(in: rect) }
            paths.stroke = path
        case .line, .arrow:
            guard let start = mark.lineStart, let end = mark.lineEnd else { return [] }
            let contentStart = CGPoint(x: start.x + offset.x, y: start.y + offset.y)
            let contentEnd = CGPoint(x: end.x + offset.x, y: end.y + offset.y)
            let path = lineOrArrowPath(kind: mark.kind, start: contentStart, end: contentEnd,
                                       width: mark.strokeWidth)
            paths.stroke = path
            if mark.kind == .arrow { paths.fill = path }
        case .highlight, .underline, .strikeout, .stickyNote, .textBox:
            return []
        }

        let layer = CAShapeLayer()
        layer.path = paths.stroke
        layer.strokeColor = paperAppearance.displayColor(mark.color.nsColor).cgColor
        layer.fillColor = mark.kind == .arrow ? paperAppearance.displayColor(mark.color.nsColor).cgColor : nil
        layer.lineWidth = mark.strokeWidth
        layer.lineJoin = .round
        layer.lineCap = .round
        layer.contentsScale = window?.backingScaleFactor ?? 2
        return [layer]
    }

    /// The eight grab handles on a selected text box: four corners and four edge midpoints.
    ///
    /// They are plain layers rather than part of the dashed halo so the pointer can see a target
    /// to grab; the hit test that decides which one the pointer is over lives in `AppState`, in
    /// page space, where the resize maths also lives.
    private func appendResizeHandles(for mark: CanvasAnnotationMark, frame: PagePlacement) {
        guard let box = mark.shapeRect else { return }
        let rect = box.offsetBy(dx: frame.leftPt, dy: frame.topPt)
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
        ]
        let side = 7 / max(zoom, 0.01)
        for point in points {
            let handle = CALayer()
            handle.frame = CGRect(x: point.x - side / 2, y: point.y - side / 2,
                                  width: side, height: side)
            handle.backgroundColor = themeColor.cgColor
            handle.borderColor = NSColor.white.cgColor
            handle.borderWidth = 1 / max(zoom, 0.01)
            handle.cornerRadius = 1.5 / max(zoom, 0.01)
            handle.contentsScale = window?.backingScaleFactor ?? 2
            marksLayer.addSublayer(handle)
            markLayers.append(handle)
        }
    }

    private func lineOrArrowPath(kind: AppState.Annotation.Kind, start: CGPoint, end: CGPoint,
                                 width: CGFloat) -> CGPath {
        let mark = CanvasAnnotationMark(
            id: "live", page: 0, kind: kind, lineStart: start, lineEnd: end,
            color: AnnotationColor(red: 0, green: 0, blue: 0, alpha: 255),
            strokeWidth: width, isSelected: false, isEditable: false)
        return AnnotationGeometry.path(for: mark)
    }

    /// The page-local halo path moved into content space.
    ///
    /// The shape is built by `AnnotationGeometry` so the checks can assert it against a text
    /// mark's quads; this method only applies the page's placement.
    private func haloPath(for mark: CanvasAnnotationMark, frame: PagePlacement) -> CGPath {
        let path = CGMutablePath()
        path.addPath(AnnotationGeometry.haloPath(for: mark),
                     transform: CGAffineTransform(translationX: frame.leftPt,
                                                  y: frame.topPt))
        return path
    }

    private func updateTransform() {
        let contentWidth = max(contentWidthPt, 1)
        let offsetX = max(0, (bounds.width - contentWidth * zoom) / 2)
        let transform = CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
                                          tx: offsetX, ty: -scrollYPt * zoom)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.setAffineTransform(transform)
        CATransaction.commit()
    }
}

extension AnnotationColor {
    /// The AppKit colour a stroke is drawn in, with its stored alpha.
    var nsColor: NSColor {
        NSColor(calibratedRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
    }
}
