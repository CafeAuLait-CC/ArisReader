import AppKit
import CoreGraphics

/// The tool the canvas is in.
///
/// One value selects exactly one tool. `select` is the implicit pointer state: no tool is armed,
/// the toolbar has no Select button, and turning any tool off (clicking it again or pressing
/// Escape) lands here. The text-markup cases (`highlight`, `underline`, `strikeout`) change both
/// what a drag *looks like* and what it commits: the swept text is drawn as the target mark while
/// the pointer is down, and that same selection becomes the annotation on release. Keeping them in
/// this enum is what makes "pen, then highlight" leave one tool active rather than two modes that
/// could both apply.
public enum AnnotationTool: String, CaseIterable, Sendable {
    /// The implicit pointer: no annotation tool is armed.
    case select
    case pen
    /// A mode rather than a drawing tool: dragging removes the ink under its pointer path
    /// instead of creating anything. It is in the same enum so exactly one tool can own the
    /// canvas.
    case eraser
    case line
    case arrow
    case rectangle
    case ellipse
    case note
    case textBox
    /// A sticky text-markup mode: every finished text selection is marked with this kind.
    case highlight
    case underline
    case strikeout
    /// A click places the stamp chosen in the toolbar menu.
    case stamp
    /// A click places the image signature the reader chose; hand-drawn signatures use the pen.
    case signature

    /// The annotation kind a drag creates, or `nil` for a tool that does not draw a stroke.
    public var kind: AppState.Annotation.Kind? {
        switch self {
        case .select, .eraser, .note, .textBox, .highlight, .underline, .strikeout, .stamp,
             .signature:
            return nil
        case .pen: return .ink
        case .line: return .line
        case .arrow: return .arrow
        case .rectangle: return .square
        case .ellipse: return .circle
        }
    }

    /// The markup kind a finished text selection becomes, or `nil` for every other tool.
    ///
    /// The three kinds are text marks, not glyphs drawn by a pointer: they live in the annotation cache,
    /// are written as `/QuadPoints`, and are hit-tested/selected through their text range.
    public var textMarkupKind: AppState.Annotation.Kind? {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeout: return .strikeout
        case .select, .pen, .eraser, .line, .arrow, .rectangle, .ellipse, .note, .textBox,
             .stamp, .signature:
            return nil
        }
    }

    /// Whether this tool turns every finished text selection into a mark.
    public var isTextMarkup: Bool { textMarkupKind != nil }

    /// The tool for one text-markup kind, or `nil` for a kind that is not markup.
    public init?(textMarkup kind: AppState.Annotation.Kind) {
        switch kind {
        case .highlight: self = .highlight
        case .underline: self = .underline
        case .strikeout: self = .strikeout
        case .ink, .square, .circle, .line, .arrow, .stickyNote, .textBox, .stamp, .signature:
            return nil
        }
    }

    /// Whether a drag with this tool is a freehand stroke rather than a corner-to-corner shape.
    public var isFreehand: Bool { self == .pen }

    /// Whether a drag with this tool removes ink rather than creating it.
    ///
    /// The eraser is a *mode*, not something that draws: it owns the pointer gesture exactly
    /// like the pen does, but a finished gesture is a deletion, not a new annotation.
    public var erasesInk: Bool { self == .eraser }

    /// Whether the tool draws a stroked mark by dragging.
    public var draws: Bool { kind != nil }

    /// Whether a click with this tool places a sticky note instead of selecting text.
    public var placesNote: Bool { self == .note }

    /// Whether this tool places a text box on a double-click.
    ///
    /// It deliberately does not draw: dragging with it armed is inert, because the box's size
    /// comes from its text, not from a rectangle the reader hauls out first.
    public var placesTextBox: Bool { self == .textBox }

    /// Whether this tool places a stamp on a click.
    public var placesStamp: Bool { self == .stamp }

    /// Whether this tool places an image signature on a click.
    public var placesSignature: Bool { self == .signature }

    public var title: String {
        switch self {
        case .select: return "Pointer"
        case .pen: return "Pen"
        case .eraser: return "Eraser"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .note: return "Sticky Note"
        case .textBox: return "Text Box"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeout: return "Strikethrough"
        case .stamp: return "Stamp"
        case .signature: return "Image Signature"
        }
    }

    public var systemImage: String {
        switch self {
        case .select: return "arrow.up.left"
        case .pen: return "pencil.tip"
        case .eraser: return "eraser"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .note: return "note.text"
        case .textBox: return "textbox"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeout: return "strikethrough"
        case .stamp: return "seal"
        case .signature: return "signature"
        }
    }
}

/// Which part of a selected text box a resize drag grabbed.
///
/// Edges and corners are distinct because they resize different axes: dragging the left edge
/// moves `minX` and leaves `maxX` where it was, while the top-left corner moves both. The canvas
/// draws a handle at each of the eight positions; the edge names are the same eight positions.
public enum TextBoxResizeHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

    /// The point on `rect` this handle sits at, in the same page space as the rect.
    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    public var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    public var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    public var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    public var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
}

/// One geometry mark as the canvas overlay draws it.
///
/// Coordinates are **page-local view space** (points at 100%, origin at the page's top-left),
/// which is exactly what the annotation cache stores and what the write-back path converts once. The
/// canvas maps them to the view with the page's placement and the current zoom.
public struct CanvasAnnotationMark: Identifiable, Equatable, Sendable {
    public let id: String
    public let page: Int
    public let kind: AppState.Annotation.Kind
    public let inkPaths: [[CGPoint]]
    public let shapeRect: CGRect?
    public let lineStart: CGPoint?
    public let lineEnd: CGPoint?
    /// The page-space quads a text mark covers, one per visual line.
    ///
    /// Empty for every kind drawn from its own geometry. For a highlight, underline or strikeout
    /// the quads come from the page's text layer: they are the mark's actual shape, so the
    /// selection halo can follow all of a multi-line mark instead of boxing the paragraph.
    public let textQuads: [CGRect]
    public let color: AnnotationColor
    public let strokeWidth: CGFloat
    public let isSelected: Bool
    /// True for the ink stroke an armed eraser is over: drawn with the same halo the select tool
    /// uses, before any press removes it.
    public let isEraseTarget: Bool
    /// False for a mark that only exists inside the PDF (it can be seen, not moved or deleted).
    public let isEditable: Bool

    public init(
        id: String,
        page: Int,
        kind: AppState.Annotation.Kind,
        inkPaths: [[CGPoint]] = [],
        shapeRect: CGRect? = nil,
        lineStart: CGPoint? = nil,
        lineEnd: CGPoint? = nil,
        textQuads: [CGRect] = [],
        color: AnnotationColor,
        strokeWidth: CGFloat,
        isSelected: Bool,
        isEraseTarget: Bool = false,
        isEditable: Bool
    ) {
        self.id = id
        self.page = page
        self.kind = kind
        self.inkPaths = inkPaths
        self.shapeRect = shapeRect
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.textQuads = textQuads
        self.color = color
        self.strokeWidth = strokeWidth
        self.isSelected = isSelected
        self.isEraseTarget = isEraseTarget
        self.isEditable = isEditable
    }

    /// The page-space box, for the selection halo and hit testing.
    public var bounds: CGRect? {
        switch kind {
        case .ink:
            let points = inkPaths.flatMap { $0 }
            guard let first = points.first else { return nil }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: max(maxX - minX, 0.01),
                          height: max(maxY - minY, 0.01))
        case .square, .circle, .stickyNote, .textBox, .stamp, .signature:
            return shapeRect
        case .line, .arrow:
            guard let start = lineStart, let end = lineEnd else { return nil }
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: max(abs(end.x - start.x), 0.01),
                          height: max(abs(end.y - start.y), 0.01))
        case .highlight, .underline, .strikeout:
            guard let first = textQuads.first else { return nil }
            return textQuads.dropFirst().reduce(first) { $0.union($1) }
        }
    }
}

/// The geometry half of the annotation code: one place that turns page-space marks into paths
/// and answers "is this point on that stroke?".
///
/// The canvas draws with [`path(for:)`], the hit test measures distance with
/// [`distance(to:from:)`], and the checks use both. That is deliberate: the tolerance a reader
/// feels when clicking a hairline must be the same number the test asserts, and a second
/// implementation of "near the stroke" would eventually disagree with the pixels.
public enum AnnotationGeometry {
    /// The most a pointer may be from a stroke's centreline and still select it, in **view**
    /// points. 4 pt is the same order as the canvas' click slop: a thin pen stroke is 2 pt wide,
    /// so half its width plus 3 pt of hand tolerance selects it without reaching text a line
    /// away. The canvas divides this by the zoom before asking page-space geometry.
    public static let hitTolerancePt: CGFloat = 4

    /// How far the eraser's pointer path may pass from an ink stroke and still remove it, in
    /// **view** points.
    ///
    /// 8 pt is twice the select tool's 4 pt allowance, because an eraser is dragged rather than
    /// aimed at one point: at 100% zoom a 2 pt pen stroke is removed when the pointer comes
    /// within 9 pt of its centreline (8 pt plus half the stroke's width), which is roughly one
    /// 12 pt text line — forgiving enough to feel like an eraser without reaching the line above
    /// or below. The canvas converts the tolerance to page points with the zoom and adds half the
    /// stroke's width there, so the distance a hand must miss by is the same at every zoom:
    /// `8 view pt + half the stroke's on-screen width`.
    public static let eraserToleranceViewPt: CGFloat = 8

    /// How much room the dashed selection halo leaves around an ink stroke, shape or placed
    /// text box, in page points. The halo is a signpost, not a fill: it should read as "this
    /// mark is selected" without covering the mark or its neighbours.
    public static let haloPaddingPt: CGFloat = 6

    /// How much room the dashed selection halo leaves around a text mark's quads, in page points.
    ///
    /// Half the box padding: a text mark is selected as text, so the outline follows the words
    /// themselves. Six points around every line would read as a box around the paragraph.
    public static let markupHaloPaddingPt: CGFloat = 3

    /// The page-space distance within which the eraser removes a `strokeWidth`-wide ink stroke at
    /// `zoom`. See ``eraserToleranceViewPt`` for the number and why it was chosen.
    public static func eraserReach(strokeWidth: CGFloat, zoom: CGFloat) -> CGFloat {
        strokeWidth / 2 + eraserToleranceViewPt / max(zoom, 0.01)
    }

    /// A path through `points`, smoothed with the midpoint-quadratic rule.
    ///
    /// A live pen delivers one sample per pointer event, which is dense but still visibly
    /// polygonal at speed. Joining each pair of samples through its midpoint with a quadratic
    /// control point keeps the curve inside the sampled polyline (it does not overshoot) and is
    /// cheap enough to run while the pointer moves.
    public static func strokePath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 2 else {
            if let point = points.first {
                path.move(to: point)
                path.addLine(to: CGPoint(x: point.x + 0.01, y: point.y))
            }
            return path
        }
        path.move(to: points[0])
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: current)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// The stroked path for a mark, including an arrowhead for `.arrow`.
    public static func path(for mark: CanvasAnnotationMark) -> CGPath {
        let path = CGMutablePath()
        switch mark.kind {
        case .ink:
            for stroke in mark.inkPaths where !stroke.isEmpty {
                path.addPath(strokePath(stroke))
            }
        case .square:
            if let rect = mark.shapeRect { path.addRect(rect) }
        case .circle:
            if let rect = mark.shapeRect { path.addEllipse(in: rect) }
        case .line, .arrow:
            guard let start = mark.lineStart, let end = mark.lineEnd else { break }
            path.move(to: start)
            path.addLine(to: end)
            if mark.kind == .arrow {
                let dx = end.x - start.x
                let dy = end.y - start.y
                let length = hypot(dx, dy)
                if length > 1e-6 {
                    let ux = dx / length
                    let uy = dy / length
                    let head = max(mark.strokeWidth * 5, 8)
                    let half = max(mark.strokeWidth * 1.8, 3)
                    let base = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
                    path.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
                    path.closeSubpath()
                }
            }
        case .highlight, .underline, .strikeout:
            break
        case .stickyNote, .textBox, .stamp, .signature:
            // These are drawn from a bitmap (the note icon, the laid-out text, the stamp or the
            // signature image), not a stroke; the overlay uses `bounds` for the selection halo.
            break
        }
        return path
    }

    /// Whether `point` (page space) is within `tolerance` points of the mark's stroke.
    ///
    /// A shape is hit on its outline, not its interior. The interior is where the reader's text
    /// lives; selecting a rectangle by clicking the text it surrounds would take the click away
    /// from text selection, which is the one thing this hit test must not do.
    public static func hitTest(_ mark: CanvasAnnotationMark, at point: CGPoint,
                               tolerance: CGFloat) -> Bool {
        let reach = tolerance + mark.strokeWidth / 2
        switch mark.kind {
        case .ink:
            for stroke in mark.inkPaths {
                if distance(point, toPolyline: stroke) <= reach { return true }
            }
            return false
        case .line, .arrow:
            guard let start = mark.lineStart, let end = mark.lineEnd else { return false }
            return distance(point, toSegmentFrom: start, to: end) <= reach
        case .square:
            guard let rect = mark.shapeRect else { return false }
            return distance(point, toRectOutline: rect) <= reach
        case .circle:
            guard let rect = mark.shapeRect else { return false }
            return distance(point, toEllipseIn: rect) <= reach
        case .highlight, .underline, .strikeout:
            // A text mark is hit on the words it covers, not on a paragraph box: the quads are
            // the lines of the marked range, so the text either side is unaffected.
            return mark.textQuads.contains {
                $0.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
            }
        case .stickyNote:
            guard let rect = mark.shapeRect else { return false }
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .textBox:
            guard let rect = mark.shapeRect else { return false }
            // A press anywhere on the box (frame or interior) is a candidate for a plain-click
            // selection; the canvas and `AppState` then use click-versus-drag to decide whether
            // it selects the box or selects the text underneath. Once the box is selected,
            // dragging its interior moves it.
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .stamp, .signature:
            guard let rect = mark.shapeRect else { return false }
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    /// The page-space rectangles the dashed selection halo is drawn around.
    ///
    /// One rectangle per text line for a text mark, so a multi-line highlight is outlined as the
    /// lines of text it covers rather than as one box around the whole paragraph. Every other
    /// editable mark keeps the single padded box it has always had.
    public static func haloRects(for mark: CanvasAnnotationMark) -> [CGRect] {
        if !mark.textQuads.isEmpty {
            return mark.textQuads.map {
                $0.insetBy(dx: -markupHaloPaddingPt, dy: -markupHaloPaddingPt)
            }
        }
        guard let bounds = mark.bounds else { return [] }
        return [bounds.insetBy(dx: -haloPaddingPt, dy: -haloPaddingPt)]
    }

    /// The dashed halo path for a mark, in page-local points.
    ///
    /// The overlay offsets this path by the page placement and strokes it with the 4-3 dash the
    /// ink and shape selection has always used; the checks compare the rectangles above with the
    /// mark's quads so the two cannot drift apart.
    public static func haloPath(for mark: CanvasAnnotationMark) -> CGPath {
        let path = CGMutablePath()
        for rect in haloRects(for: mark) {
            let radius = min(4, max(0, min(rect.width, rect.height) / 2))
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }

    /// Distance from a point to a polyline, or infinity for an empty one.
    public static func distance(_ point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        var best = CGFloat.infinity
        for index in 1..<points.count {
            best = min(best, distance(point, toSegmentFrom: points[index - 1], to: points[index]))
        }
        return best
    }

    /// Distance from a point to a line segment, the primitive every hit test above uses.
    public static func distance(_ point: CGPoint, toSegmentFrom start: CGPoint,
                                to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-12 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    public static func distance(_ point: CGPoint, toRectOutline rect: CGRect) -> CGFloat {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ]
        var best = CGFloat.infinity
        for index in 0..<4 {
            best = min(best, distance(point, toSegmentFrom: corners[index],
                                      to: corners[(index + 1) % 4]))
        }
        return best
    }

    public static func distance(_ point: CGPoint, toEllipseIn rect: CGRect) -> CGFloat {
        // A polygon whose vertices lie on the ellipse converges to the outline as the sample
        // count grows; 96 samples put the sagitta below 0.001 pt for an A4-sized ellipse.
        let samples = 96
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2
        let ry = rect.height / 2
        var best = CGFloat.infinity
        var previous = CGPoint(x: centre.x + rx, y: centre.y)
        for index in 1...samples {
            let angle = 2 * Double.pi * Double(index) / Double(samples)
            let current = CGPoint(x: centre.x + rx * CGFloat(cos(angle)),
                                  y: centre.y + ry * CGFloat(sin(angle)))
            best = min(best, distance(point, toSegmentFrom: previous, to: current))
            previous = current
        }
        return best
    }

    /// Distance from a pointer segment to a stroke polyline, or infinity for an empty stroke.
    ///
    /// An eraser gesture is a **path**, not a series of independent points: a fast drag delivers
    /// one sample every few dozen points, and a stroke that crosses the line between two samples
    /// must still be erased. Taking the minimum distance between the two *segments* (not between
    /// their endpoints) is what makes that true.
    public static func distance(fromSegment start: CGPoint, to end: CGPoint,
                                andPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else {
            return distance(first, toSegmentFrom: start, to: end)
        }
        var best = CGFloat.infinity
        for index in 1..<points.count {
            best = min(best, distance(fromSegment: start, to: end,
                                      andSegment: points[index - 1], points[index]))
        }
        return best
    }

    /// Distance between two line segments; zero when they cross or touch.
    public static func distance(fromSegment a1: CGPoint, to a2: CGPoint,
                                andSegment b1: CGPoint, _ b2: CGPoint) -> CGFloat {
        if segmentsIntersect(a1, a2, b1, b2) { return 0 }
        return min(
            distance(a1, toSegmentFrom: b1, to: b2),
            distance(a2, toSegmentFrom: b1, to: b2),
            distance(b1, toSegmentFrom: a1, to: a2),
            distance(b2, toSegmentFrom: a1, to: a2)
        )
    }

    /// Whether two line segments cross or touch, including collinear overlap.
    public static func segmentsIntersect(_ a1: CGPoint, _ a2: CGPoint,
                                         _ b1: CGPoint, _ b2: CGPoint) -> Bool {
        func orientation(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
        }
        func liesOnSegment(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
            q.x <= max(p.x, r.x) && q.x >= min(p.x, r.x)
                && q.y <= max(p.y, r.y) && q.y >= min(p.y, r.y)
        }
        let o1 = orientation(a1, a2, b1)
        let o2 = orientation(a1, a2, b2)
        let o3 = orientation(b1, b2, a1)
        let o4 = orientation(b1, b2, a2)
        let epsilon: CGFloat = 1e-9
        let straddles = { (first: CGFloat, second: CGFloat) in
            (first > epsilon && second < -epsilon) || (first < -epsilon && second > epsilon)
        }
        if straddles(o1, o2) && straddles(o3, o4) { return true }
        if abs(o1) <= epsilon && liesOnSegment(a1, b1, a2) { return true }
        if abs(o2) <= epsilon && liesOnSegment(a1, b2, a2) { return true }
        if abs(o3) <= epsilon && liesOnSegment(b1, a1, b2) { return true }
        if abs(o4) <= epsilon && liesOnSegment(b1, a2, b2) { return true }
        return false
    }

    /// The part of a segment inside an axis-aligned rectangle, or `nil` when it misses it.
    ///
    /// A drag in continuous layout can cross a page boundary between two pointer samples. The
    /// eraser clips each sample segment to every page it touches before measuring distances in
    /// that page's own space; without the clip, the part of the drag on the next page would be
    /// compared against this page's strokes at the wrong coordinates.
    public static func clippedSegment(from start: CGPoint, to end: CGPoint,
                                      in rect: CGRect) -> (start: CGPoint, end: CGPoint)? {
        var t0: CGFloat = 0
        var t1: CGFloat = 1
        let dx = end.x - start.x
        let dy = end.y - start.y
        let checks: [(CGFloat, CGFloat)] = [
            (-dx, start.x - rect.minX),
            (dx, rect.maxX - start.x),
            (-dy, start.y - rect.minY),
            (dy, rect.maxY - start.y),
        ]
        for (p, q) in checks {
            if abs(p) < 1e-12 {
                if q < 0 { return nil }
                continue
            }
            let r = q / p
            if p < 0 {
                if r > t1 { return nil }
                if r > t0 { t0 = r }
            } else {
                if r < t0 { return nil }
                if r < t1 { t1 = r }
            }
        }
        return (
            CGPoint(x: start.x + t0 * dx, y: start.y + t0 * dy),
            CGPoint(x: start.x + t1 * dx, y: start.y + t1 * dy)
        )
    }
}

/// A stroked mark the canvas has just finished drawing, in page-local view space.
///
/// The canvas hands the whole gesture over once, on mouse-up. It never calls back per pointer
/// event: the live preview is drawn by the canvas itself, so a long stroke cannot queue a
/// SwiftUI update for every sample and fall behind the pointer.
public struct AnnotationDraft: Equatable, Sendable {
    public let kind: AppState.Annotation.Kind
    public let page: Int
    public let inkPaths: [[CGPoint]]
    public let shapeRect: CGRect?
    public let lineStart: CGPoint?
    public let lineEnd: CGPoint?

    public init(
        kind: AppState.Annotation.Kind,
        page: Int,
        inkPaths: [[CGPoint]] = [],
        shapeRect: CGRect? = nil,
        lineStart: CGPoint? = nil,
        lineEnd: CGPoint? = nil
    ) {
        self.kind = kind
        self.page = page
        self.inkPaths = inkPaths
        self.shapeRect = shapeRect
        self.lineStart = lineStart
        self.lineEnd = lineEnd
    }
}
