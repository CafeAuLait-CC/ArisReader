import AppKit
import CoreGraphics

/// The tool the canvas is in.
///
/// One value selects exactly one tool. The text-markup cases (`highlight`, `underline`,
/// `strikeout`) do not change what a drag *draws*: a drag still selects text, and the selection
/// is turned into that kind of mark when it is released. Keeping them in this enum is what makes
/// "pen, then highlight" leave one tool active rather than two modes that could both apply.
public enum AnnotationTool: String, CaseIterable, Sendable {
    case select
    case pen
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

    /// The annotation kind a drag creates, or `nil` for a tool that does not draw a stroke.
    public var kind: AppState.Annotation.Kind? {
        switch self {
        case .select, .note, .textBox, .highlight, .underline, .strikeout: return nil
        case .pen: return .ink
        case .line: return .line
        case .arrow: return .arrow
        case .rectangle: return .square
        case .ellipse: return .circle
        }
    }

    /// The markup kind a finished text selection becomes, or `nil` for every other tool.
    ///
    /// The three kinds are text marks, not glyphs drawn by a pointer: they live in the sidecar,
    /// are written as `/QuadPoints`, and are hit-tested/selected through their text range.
    public var textMarkupKind: AppState.Annotation.Kind? {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeout: return .strikeout
        case .select, .pen, .line, .arrow, .rectangle, .ellipse, .note, .textBox: return nil
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
        case .ink, .square, .circle, .line, .arrow, .stickyNote, .textBox: return nil
        }
    }

    /// Whether a drag with this tool is a freehand stroke rather than a corner-to-corner shape.
    public var isFreehand: Bool { self == .pen }

    /// Whether the tool draws a stroked mark by dragging.
    public var draws: Bool { kind != nil }

    /// Whether a click with this tool places a sticky note instead of selecting text.
    public var placesNote: Bool { self == .note }

    /// Whether a drag with this tool creates a text box.
    public var placesTextBox: Bool { self == .textBox }

    public var title: String {
        switch self {
        case .select: return "Select"
        case .pen: return "Pen"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .note: return "Sticky Note"
        case .textBox: return "Text Box"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeout: return "Strikethrough"
        }
    }

    public var systemImage: String {
        switch self {
        case .select: return "arrow.up.left"
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .note: return "note.text"
        case .textBox: return "textbox"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeout: return "strikethrough"
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
/// which is exactly what the sidecar stores and what the write-back path converts once. The
/// canvas maps them to the view with the page's placement and the current zoom.
public struct CanvasAnnotationMark: Identifiable, Equatable, Sendable {
    public let id: String
    public let page: Int
    public let kind: AppState.Annotation.Kind
    public let inkPaths: [[CGPoint]]
    public let shapeRect: CGRect?
    public let lineStart: CGPoint?
    public let lineEnd: CGPoint?
    public let color: AnnotationColor
    public let strokeWidth: CGFloat
    public let isSelected: Bool
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
        color: AnnotationColor,
        strokeWidth: CGFloat,
        isSelected: Bool,
        isEditable: Bool
    ) {
        self.id = id
        self.page = page
        self.kind = kind
        self.inkPaths = inkPaths
        self.shapeRect = shapeRect
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.color = color
        self.strokeWidth = strokeWidth
        self.isSelected = isSelected
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
        case .square, .circle, .stickyNote, .textBox:
            return shapeRect
        case .line, .arrow:
            guard let start = lineStart, let end = lineEnd else { return nil }
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: max(abs(end.x - start.x), 0.01),
                          height: max(abs(end.y - start.y), 0.01))
        case .highlight, .underline, .strikeout:
            return nil
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
        case .stickyNote, .textBox:
            // These are drawn from a bitmap (the note icon or the laid-out text), not a stroke;
            // the overlay uses `bounds` for the selection halo. No vector path to return.
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
            return false
        case .stickyNote:
            guard let rect = mark.shapeRect else { return false }
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .textBox:
            guard let rect = mark.shapeRect else { return false }
            // A text box is selected by its frame, never by its interior while it is not
            // selected: the text under it must stay selectable. Once selected, dragging its
            // inside moves it, which is why the interior counts only then.
            if distance(point, toRectOutline: rect) <= reach { return true }
            return mark.isSelected && rect.contains(point)
        }
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
