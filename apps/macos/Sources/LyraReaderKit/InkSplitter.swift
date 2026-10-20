import CoreGraphics
import Foundation

/// Splits one stored ink polyline where the eraser's pointer path reaches it.
///
/// The eraser removes the union of **capsules**: every pointer sample is a line segment, and
/// everything within `reach` of that segment is under the eraser. `reach` is the same number the
/// whole-stroke hit test uses (`AnnotationGeometry.eraserReach`): half the stroke's width plus
/// the 8 view-point eraser allowance converted to page points. Including half the width is what
/// makes a wide stroke as easy to catch as a thin one; the rest is the hand tolerance.
///
/// The split keeps the stroke's own geometry:
///
/// * Every surviving point is an **original** point, bit for bit. No point is averaged,
///   simplified, decimated or moved.
/// * A new point is added only where the capsule boundary crosses an original segment. That
///   point is a linear interpolation of that segment, so it lies on the geometry that was
///   already there.
/// * The boundary is found by bisection, not by snapping to a sample. The check below uses 48
///   halvings, which puts the cut within ~1e-14 of a segment's length — far below the f32
///   coordinates a PDF stores, so it cannot visibly reshape an end.
/// * A graze that only touches the stroke tangentially is ignored: the two cut points would be
///   the same point, and splitting there would add an invisible seam for nothing.
///
/// The stroke is drawn with round caps and joins (the canvas' `lineCap`/`lineJoin` and the PDF
/// appearance stream's `1 J 1 j`). A cut therefore gives the new end its normal round cap, which
/// extends half the stroke width past the cut centreline. That is not extra loss or a reshaped
/// end: the reach is `eraser radius + half the width`, so the cap's outer edge lands exactly on
/// the eraser's radius. The kept ink is the ink outside the eraser's swept disk (the anti-aliased
/// boundary aside), and no point outside the reach is moved to compensate.
///
/// ## Cost
///
/// A pointer segment is first rejected against the original segment's bounding box expanded by
/// `reach`, so a split costs O(surviving path points) per pointer sample and only pays for the
/// 48-step bisection on the few segments the eraser actually touches. A 600-point signature
/// against a 60-sample drag is a few dozen thousand cheap box tests and one or two bisections;
/// no points are decimated.
public struct InkStrokeSplitter: Equatable, Sendable {
    /// The stroke exactly as it was stored.
    public let points: [CGPoint]
    /// Distance from the pointer centreline within which ink is removed, in page points.
    public let reach: CGFloat

    /// Removed parameter intervals, one sorted, merged list per original segment.
    private var removed: [[ClosedRange<Double>]]
    /// True when a one-point stroke was touched (it has no segments to carry intervals).
    private var removesPoint = false

    /// How many original segments this splitter has touched. Exposed for the checks and for the
    /// status line; it is not the number of surviving pieces.
    public private(set) var touchedSegmentCount = 0

    public init(points: [CGPoint], reach: CGFloat) {
        self.points = points
        self.reach = max(reach, 0)
        self.removed = Array(repeating: [], count: max(points.count - 1, 0))
    }

    /// Removes everything within `reach` of the pointer segment `start`→`end`.
    ///
    /// Returns true when the stroke's surviving geometry changed. Adding a pointer segment that
    /// covers ground an earlier sample already covered is a no-op, so a slow drag cannot grow
    /// the cut list or make the result depend on event frequency.
    @discardableResult
    public mutating func remove(pointerFrom start: CGPoint, to end: CGPoint) -> Bool {
        guard reach.isFinite, reach >= 0 else { return false }
        guard !points.isEmpty else { return false }
        if points.count == 1 {
            guard !removesPoint,
                  AnnotationGeometry.distance(points[0], toSegmentFrom: start, to: end) <= reach
            else { return false }
            removesPoint = true
            return true
        }

        let pointerMinX = min(start.x, end.x) - reach
        let pointerMaxX = max(start.x, end.x) + reach
        let pointerMinY = min(start.y, end.y) - reach
        let pointerMaxY = max(start.y, end.y) + reach

        var changed = false
        for index in 0..<(points.count - 1) {
            let first = points[index]
            let second = points[index + 1]
            // Cheap rejection before the exact segment-to-segment distance: a segment whose
            // expanded box misses the pointer's expanded box cannot be within reach.
            let segmentMinX = min(first.x, second.x)
            let segmentMaxX = max(first.x, second.x)
            let segmentMinY = min(first.y, second.y)
            let segmentMaxY = max(first.y, second.y)
            if segmentMaxX < pointerMinX || segmentMinX > pointerMaxX
                || segmentMaxY < pointerMinY || segmentMinY > pointerMaxY {
                continue
            }
            guard let interval = Self.removedInterval(
                from: first, to: second, pointerFrom: start, to: end, reach: reach
            ) else { continue }
            if merge(interval, into: index) {
                changed = true
                touchedSegmentCount += 1
            }
        }
        return changed
    }

    /// The consecutive pieces of the original polyline that the eraser has not reached.
    ///
    /// In original path order. Each piece has at least two points; a piece that is entirely
    /// under the eraser is absent, and a stroke the eraser covered completely yields `[]`.
    public var survivingPaths: [[CGPoint]] {
        guard points.count > 1 else {
            // A one-point path cannot be drawn as a segment; it survives untouched unless the
            // eraser landed on it. Callers only ask for survivors after `remove` returned true,
            // which for a one-point path means `removesPoint`.
            return removesPoint ? [] : [points]
        }
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []

        func point(at parameter: Double, on index: Int) -> CGPoint {
            let first = points[index]
            let second = points[index + 1]
            let t = CGFloat(min(max(parameter, 0), 1))
            return CGPoint(x: first.x + (second.x - first.x) * t,
                           y: first.y + (second.y - first.y) * t)
        }
        func finishPiece() {
            if current.count >= 2 { result.append(current) }
            current = []
        }

        for index in 0..<(points.count - 1) {
            let first = points[index]
            let second = points[index + 1]
            let intervals = removed[index]
            if intervals.isEmpty {
                if current.isEmpty { current.append(first) }
                current.append(second)
                continue
            }

            var cursor = 0.0
            for interval in intervals {
                let lower = max(interval.lowerBound, 0)
                let upper = min(interval.upperBound, 1)
                guard upper > lower else { continue }
                if lower > cursor + Self.parameterEpsilon {
                    if current.isEmpty { current.append(point(at: cursor, on: index)) }
                    current.append(point(at: lower, on: index))
                    finishPiece()
                }
                cursor = max(cursor, upper)
                if cursor >= 1 { break }
            }
            if cursor < 1 - Self.parameterEpsilon {
                if current.isEmpty { current.append(point(at: cursor, on: index)) }
                current.append(second)
            }
        }
        finishPiece()
        return result
    }

    /// True when the eraser has removed the stroke completely.
    public var isFullyRemoved: Bool {
        if points.count == 1 { return removesPoint }
        guard !points.isEmpty else { return false }
        return survivingPaths.isEmpty
    }

    /// The parameter intervals (in the original segment's 0…1 space) covered by the eraser.
    /// Exposed for the checks so they can prove the cut points sit on the original geometry.
    public func removedIntervals(onSegment index: Int) -> [ClosedRange<Double>] {
        guard removed.indices.contains(index) else { return [] }
        return removed[index]
    }

    // MARK: - Interval arithmetic

    /// The sub-interval of `first`→`second` that lies within `reach` of the pointer segment.
    ///
    /// The set of points within `reach` of a segment is a capsule, which is convex, so its
    /// intersection with a straight segment is a single interval. The closest approach between
    /// the two segments is therefore the midpoint of that interval; two bisections find the
    /// ends. A tangent (empty interval) returns nil.
    private static func removedInterval(
        from first: CGPoint, to second: CGPoint,
        pointerFrom pointerStart: CGPoint, to pointerEnd: CGPoint,
        reach: CGFloat
    ) -> ClosedRange<Double>? {
        guard let closest = closestApproach(
            first, second, pointerStart, pointerEnd
        ) else { return nil }
        if closest.distance > reach + 1e-9 { return nil }

        func distanceAt(_ parameter: Double) -> CGFloat {
            let t = CGFloat(min(max(parameter, 0), 1))
            let point = CGPoint(x: first.x + (second.x - first.x) * t,
                                y: first.y + (second.y - first.y) * t)
            return AnnotationGeometry.distance(point,
                                               toSegmentFrom: pointerStart, to: pointerEnd)
        }

        let middle = min(max(closest.parameter, 0), 1)
        // The exact closest approach is inside the capsule; if floating-point rounding puts its
        // distance a hair over the reach, treat it as the boundary point rather than dropping a
        // genuine hit.
        guard distanceAt(middle) <= reach + 1e-7 else { return nil }

        let lower: Double
        if distanceAt(0) <= reach {
            lower = 0
        } else {
            var outside = 0.0
            var inside = middle
            for _ in 0..<48 {
                let mid = (outside + inside) / 2
                if distanceAt(mid) <= reach { inside = mid } else { outside = mid }
            }
            lower = inside
        }

        let upper: Double
        if distanceAt(1) <= reach {
            upper = 1
        } else {
            var inside = middle
            var outside = 1.0
            for _ in 0..<48 {
                let mid = (inside + outside) / 2
                if distanceAt(mid) <= reach { inside = mid } else { outside = mid }
            }
            upper = inside
        }

        // A tangent removes a zero-length piece. Ignoring it keeps the stroke one piece and
        // avoids an invisible seam; see the type comment.
        guard upper - lower > parameterEpsilon else { return nil }
        return lower...upper
    }

    /// Closest point on `first`→`second` to the segment `pointerStart`→`pointerEnd`, as a
    /// parameter in 0…1 plus the distance between the segments.
    private static func closestApproach(
        _ first: CGPoint, _ second: CGPoint,
        _ pointerStart: CGPoint, _ pointerEnd: CGPoint
    ) -> (parameter: Double, distance: CGFloat)? {
        let ux = second.x - first.x
        let uy = second.y - first.y
        let vx = pointerEnd.x - pointerStart.x
        let vy = pointerEnd.y - pointerStart.y
        let wx = first.x - pointerStart.x
        let wy = first.y - pointerStart.y
        let a = ux * ux + uy * uy
        let b = ux * vx + uy * vy
        let c = vx * vx + vy * vy
        let d = wx * ux + wy * uy
        let e = wx * vx + wy * vy

        // The minimum over the closed parameter square is either the unconstrained stationary
        // point (when it lies inside) or one of the four edges. The two edges at t=0 and t=1
        // map to t=0/1; the edges at s=0 and s=1 give the projections below. Evaluating these
        // candidates is exact and avoids a search.
        var candidates: [Double] = [0, 1]
        let determinant = a * c - b * b
        if abs(determinant) > 1e-12 {
            let t = (b * e - c * d) / determinant
            let s = (b * t + e) / c
            if t >= 0, t <= 1, s >= 0, s <= 1 { candidates.append(t) }
        }
        if a > 1e-12 {
            candidates.append(-d / a)
            candidates.append((b - d) / a)
        }

        var bestParameter = 0.0
        var bestDistance = CGFloat.infinity
        for candidate in candidates {
            let t = min(max(candidate, 0), 1)
            let point = CGPoint(x: first.x + ux * CGFloat(t),
                                y: first.y + uy * CGFloat(t))
            let distance = AnnotationGeometry.distance(point,
                                                       toSegmentFrom: pointerStart,
                                                       to: pointerEnd)
            if distance < bestDistance {
                bestDistance = distance
                bestParameter = t
            }
        }
        guard bestDistance.isFinite else { return nil }
        return (bestParameter, bestDistance)
    }

    /// Adds an interval to one segment's removed list, merging overlaps and touching runs.
    /// Returns true when the covered length actually grew.
    private mutating func merge(_ interval: ClosedRange<Double>, into index: Int) -> Bool {
        let old = removed[index]
        var all = old
        all.append(interval)
        all.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in all {
            if let last = merged.last, range.lowerBound <= last.upperBound + Self.parameterEpsilon {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound,
                                                                range.upperBound)
            } else {
                merged.append(range)
            }
        }
        guard merged != old else { return false }
        removed[index] = merged
        return true
    }

    /// Parameter units below this are the same point. 1e-12 of a 10 000 pt segment is 1e-8 pt,
    /// far below any raster or PDF f32 coordinate.
    private static let parameterEpsilon = 1e-12
}
