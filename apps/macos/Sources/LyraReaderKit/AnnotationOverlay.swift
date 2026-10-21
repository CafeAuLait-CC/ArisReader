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
///   its path once in page-local coordinates and the segment containers clip it.
/// * The live pen has to be updated from inside the pointer event. Calling AppState for every
///   sample and waiting for a SwiftUI pass adds a run-loop turn between the pointer and the ink;
///   the drag here goes straight into the layer tree and the display composites it on the next
///   frame, with no model write until mouse-up.
///
/// Coordinates: every path this view stores is in **page-local points**; a segment container
/// translates it to content points and clips it to the display segment it belongs to. A torn
/// page therefore draws a stroke that crosses the tear as two clipped pieces, one above the card
/// and one below it, without changing the mark's page geometry.
final class AnnotationOverlayView: NSView {
    private let container = CALayer()
    private let marksLayer = CALayer()
    private let redactionsLayer = CALayer()
    private let liveLayer = CALayer()
    /// Every layer this view added below the three content layers, so a rebuild removes exactly
    /// its own output and nothing else.
    private var markLayers: [CALayer] = []

    /// The page's display segments. An untorn page has one; a torn page has two, each with the
    /// page-local range it shows (`sourceTopPt`/`sourceHeightPt`).
    private var framesList: [PagePlacement] = []
    private var marks: [CanvasAnnotationMark] = []
    private var redactionMarks: [CanvasRedactionMark] = []
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
        container.addSublayer(liveLayer)
        container.anchorPoint = CGPoint(x: 0, y: 0)
        container.position = .zero
        container.bounds = CGRect(origin: .zero, size: frameRect.size)
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
            renderLive()
        }
        if framesChanged {
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
        self.framesList = frames
        guard marks != redactionMarks || framesChanged else { return }
        self.redactionMarks = marks
        rebuildRedactionLayers()
    }

    // MARK: - Page-local ↔ content

    private func segments(for page: Int) -> [PagePlacement] {
        framesList.filter { $0.index == page }
    }

    /// The page-local point under a content point, or nil when the point is in a tear's gap.
    private func pageLocalPoint(atContent point: CGPoint, page: Int) -> CGPoint? {
        for frame in segments(for: page) {
            let rect = CGRect(x: frame.leftPt, y: frame.topPt,
                              width: frame.widthPt, height: frame.heightPt)
            guard rect.contains(point) else { continue }
            return CGPoint(
                x: point.x - frame.leftPt,
                y: point.y - frame.topPt + frame.sourceTopPt
            )
        }
        return nil
    }

    /// A page-local point in content space; nil only when the page-local Y is outside the
    /// page's displayed range.
    private func contentPoint(forPageLocal local: CGPoint, page: Int) -> CGPoint? {
        for frame in segments(for: page)
        where local.y >= frame.sourceTopPt - 0.001
            && local.y <= frame.sourceTopPt + frame.sourceHeightPt + 0.001 {
            return CGPoint(x: frame.leftPt + local.x,
                           y: frame.topPt + local.y - frame.sourceTopPt)
        }
        return nil
    }

    /// One clipping container per display segment, each holding a shape built from the same
    /// page-local path. The container's bounds are the segment's content rect, so the paper cut
    /// is exactly where the card's gap is.
    private func clippedContentLayers(
        for localPath: CGPath,
        page: Int,
        stroke: NSColor?,
        fill: NSColor?,
        lineWidth: CGFloat,
        dashed: Bool = false
    ) -> [CALayer] {
        var result: [CALayer] = []
        for frame in segments(for: page) {
            let rect = CGRect(x: frame.leftPt, y: frame.topPt,
                              width: frame.widthPt, height: frame.heightPt)
            guard rect.width > 0.1, rect.height > 0.1 else { continue }
            let clip = CALayer()
            clip.frame = rect
            clip.masksToBounds = true
            clip.isGeometryFlipped = true
            clip.contentsScale = window?.backingScaleFactor ?? 2
            let shape = CAShapeLayer()
            shape.frame = CGRect(origin: .zero, size: rect.size)
            var translate = CGAffineTransform(translationX: 0, y: -frame.sourceTopPt)
            shape.path = localPath.copy(using: &translate)
            shape.strokeColor = stroke?.cgColor
            shape.fillColor = fill?.cgColor
            shape.lineWidth = lineWidth
            shape.lineJoin = .round
            shape.lineCap = .round
            if dashed {
                let unit = 1 / max(zoom, 0.01)
                shape.lineDashPattern = [NSNumber(value: 4 * unit), NSNumber(value: 3 * unit)]
            }
            shape.contentsScale = window?.backingScaleFactor ?? 2
            clip.addSublayer(shape)
            result.append(clip)
        }
        return result
    }

    // MARK: - Redactions

    private func rebuildRedactionLayers() {
        redactionsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for mark in redactionMarks {
            let rect = CGRect(x: mark.rect.minX, y: mark.rect.minY,
                              width: mark.rect.width, height: mark.rect.height)
            let path = CGPath(rect: rect, transform: nil)
            let layers = clippedContentLayers(
                for: path,
                page: mark.page,
                stroke: NSColor.systemRed.withAlphaComponent(0.9),
                fill: NSColor(calibratedWhite: 0.08, alpha: 0.55),
                lineWidth: 1.2 / max(zoom, 0.01)
            )
            for layer in layers {
                if let shape = layer.sublayers?.first as? CAShapeLayer {
                    shape.lineDashPattern = [4, 3]
                }
                redactionsLayer.addSublayer(layer)
            }
        }
    }

    // MARK: - Hit testing

    /// The page-local points of the mark under a content point, or `nil`.
    ///
    /// This is the same `AnnotationGeometry.hitTest` the checks call; only editable marks are
    /// considered, because selecting a PDF's own ink would promise an edit this build cannot
    /// make. The tolerance is in view points, converted to content points by the zoom.
    func hitTestMark(atContentPoint point: CGPoint, toleranceViewPt: CGFloat) -> CanvasAnnotationMark? {
        let tolerance = toleranceViewPt / max(zoom, 0.01)
        for mark in marks.reversed() where mark.isEditable {
            guard let local = pageLocalPoint(atContent: point, page: mark.page) else { continue }
            if AnnotationGeometry.hitTest(mark, at: local, tolerance: tolerance) { return mark }
        }
        return nil
    }

    // MARK: - Live gesture

    func beginLiveStroke(kind: AppState.Annotation.Kind, page: Int, at point: CGPoint) {
        guard !segments(for: page).isEmpty else { return }
        liveKind = kind
        livePage = page
        liveStart = point
        liveEnd = point
        livePoints = kind == .ink ? [point] : []
        renderLive()
    }

    /// Extends the preview with a content point. The point is converted to page-local space
    /// first, so a drag across a tear keeps describing one page mark; the pointer is in the
    /// card's gap for a moment, and that sample is ignored rather than folded into the path.
    func extendLiveStroke(atContentPoint content: CGPoint) {
        guard let kind = liveKind, let page = livePage,
              let local = pageLocalPoint(atContent: content, page: page) else { return }
        switch kind {
        case .ink:
            if let last = livePoints.last, hypot(local.x - last.x, local.y - last.y) < 0.4 {
                return
            }
            livePoints.append(local)
        case .line, .arrow:
            liveEnd = local
        case .square, .circle:
            liveEnd = local
        case .highlight, .underline, .strikeout, .stickyNote, .textBox, .stamp, .signature:
            break
        }
        renderLive()
    }

    /// Ends the preview. Returns the page-local draft only when the gesture described a mark.
    func finishLiveStroke(in frames: [PagePlacement]) -> AnnotationDraft? {
        _ = frames
        defer {
            liveKind = nil
            livePage = nil
            livePoints = []
            liveLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
        guard let kind = liveKind, let page = livePage else { return nil }
        switch kind {
        case .ink:
            guard livePoints.count >= 2 else { return nil }
            return AnnotationDraft(kind: .ink, page: page, inkPaths: [livePoints])
        case .line, .arrow:
            let start = liveStart
            let end = liveEnd
            guard hypot(end.x - start.x, end.y - start.y) >= 1 else { return nil }
            return AnnotationDraft(kind: kind, page: page, lineStart: start, lineEnd: end)
        case .square, .circle:
            let start = liveStart
            let end = liveEnd
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return AnnotationDraft(kind: kind, page: page, shapeRect: rect)
        case .highlight, .underline, .strikeout, .stickyNote, .textBox, .stamp, .signature:
            return nil
        }
    }

    func cancelLiveStroke() {
        liveKind = nil
        livePage = nil
        livePoints = []
        liveLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    // MARK: - Live gesture state

    private var liveKind: AppState.Annotation.Kind?
    private var livePage: Int?
    private var livePoints: [CGPoint] = []
    private var liveStart: CGPoint = .zero
    private var liveEnd: CGPoint = .zero

    private func renderLive() {
        liveLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let kind = liveKind, let page = livePage else { return }
        let strokePath = CGMutablePath()
        switch kind {
        case .ink:
            guard !livePoints.isEmpty else { return }
            strokePath.addPath(AnnotationGeometry.strokePath(livePoints))
        case .line, .arrow:
            guard hypot(liveEnd.x - liveStart.x, liveEnd.y - liveStart.y) > 0.1 else { return }
            strokePath.addPath(lineOrArrowPath(kind: kind, start: liveStart, end: liveEnd,
                                               width: strokeWidth))
        case .square, .circle:
            let rect = CGRect(x: min(liveStart.x, liveEnd.x), y: min(liveStart.y, liveEnd.y),
                              width: abs(liveEnd.x - liveStart.x),
                              height: abs(liveEnd.y - liveStart.y))
            guard rect.width > 0.1, rect.height > 0.1 else { return }
            if kind == .square { strokePath.addRect(rect) } else { strokePath.addEllipse(in: rect) }
        case .highlight, .underline, .strikeout, .stickyNote, .textBox, .stamp, .signature:
            return
        }
        let layers = clippedContentLayers(
            for: strokePath,
            page: page,
            stroke: strokeColor,
            fill: nil,
            lineWidth: max(strokeWidth, 0.1)
        )
        for layer in layers { liveLayer.addSublayer(layer) }
    }

    // MARK: - Committed marks

    private func rebuildMarkLayers() {
        marksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        markLayers = []
        for mark in marks where !segments(for: mark.page).isEmpty {
            for layer in layers(for: mark) {
                marksLayer.addSublayer(layer)
                markLayers.append(layer)
            }
            if mark.isSelected {
                let halo = AnnotationGeometry.haloPath(for: mark)
                for layer in clippedContentLayers(
                    for: halo, page: mark.page,
                    stroke: themeColor.withAlphaComponent(0.85), fill: nil,
                    lineWidth: 1 / max(zoom, 0.01), dashed: true
                ) {
                    marksLayer.addSublayer(layer)
                    markLayers.append(layer)
                }
                if mark.kind == .textBox || mark.kind.isStampArtwork {
                    appendResizeHandles(for: mark)
                }
            }
            if mark.isEraseTarget {
                let halo = AnnotationGeometry.haloPath(for: mark)
                for layer in clippedContentLayers(
                    for: halo, page: mark.page,
                    stroke: themeColor.withAlphaComponent(0.85), fill: nil,
                    lineWidth: 1 / max(zoom, 0.01), dashed: true
                ) {
                    marksLayer.addSublayer(layer)
                    markLayers.append(layer)
                }
            }
        }
    }

    private func layers(for mark: CanvasAnnotationMark) -> [CALayer] {
        let strokePath = CGMutablePath()
        switch mark.kind {
        case .ink:
            for stroke in mark.inkPaths where !stroke.isEmpty {
                strokePath.addPath(AnnotationGeometry.strokePath(stroke))
            }
        case .square, .circle:
            guard let rect = mark.shapeRect else { return [] }
            if mark.kind == .square { strokePath.addRect(rect) } else { strokePath.addEllipse(in: rect) }
        case .line, .arrow:
            guard let start = mark.lineStart, let end = mark.lineEnd else { return [] }
            strokePath.addPath(lineOrArrowPath(kind: mark.kind, start: start, end: end,
                                               width: mark.strokeWidth))
        case .highlight, .underline, .strikeout, .stickyNote, .textBox, .stamp, .signature:
            // Drawn by the canvas as a texture (a note icon, laid-out text, a stamp badge or a
            // signature image); this layer only draws the selection halo and the handles.
            return []
        }
        let color = paperAppearance.displayColor(mark.color.nsColor)
        return clippedContentLayers(
            for: strokePath,
            page: mark.page,
            stroke: color,
            fill: mark.kind == .arrow ? color : nil,
            lineWidth: mark.strokeWidth
        )
    }

    /// The eight grab handles on a selected text box: four corners and four edge midpoints.
    ///
    /// They are plain layers rather than part of the dashed halo so the pointer can see a target
    /// to grab; the hit test that decides which one the pointer is over lives in `AppState`, in
    /// page space, where the resize maths also lives. A torn page maps each handle's page point
    /// through the same piecewise conversion as a click.
    private func appendResizeHandles(for mark: CanvasAnnotationMark) {
        guard let box = mark.shapeRect else { return }
        let side = 7 / max(zoom, 0.01)
        let points = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.midX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.midY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.midX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX, y: box.midY),
        ]
        for local in points {
            guard let point = contentPoint(forPageLocal: local, page: mark.page) else { continue }
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
