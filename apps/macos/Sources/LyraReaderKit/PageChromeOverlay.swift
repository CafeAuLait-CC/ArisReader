import AppKit
import QuartzCore

/// Page geometry, independent of raster tiles: a tiled page still has exactly one edge.
package enum PageChromeGeometry {
    package static func rectangles(frames: [PagePlacement], viewport: CGSize,
                                   contentWidthPt: CGFloat, zoom: CGFloat, scrollYPt: CGFloat) -> [CGRect] {
        let offset = max(0, (viewport.width - contentWidthPt * zoom) / 2)
        let visible = CGRect(origin: .zero, size: viewport).insetBy(dx: -20, dy: -20)
        return frames.compactMap { frame in
            let rect = CGRect(x: offset + frame.leftPt * zoom, y: (frame.topPt - scrollYPt) * zoom,
                              width: frame.widthPt * zoom, height: frame.heightPt * zoom)
            return rect.intersects(visible) ? rect : nil
        }
    }

    package struct TornEdge: Equatable {
        package let points: [CGPoint]
        package let baseline: CGFloat
    }

    /// Derive the two cut edges from paired display segments, never from raster tiles.
    /// Teeth extend only into the reserved gap; their pattern stays attached to the paper.
    package static func tornEdges(frames: [PagePlacement], viewport: CGSize,
                                  contentWidthPt: CGFloat, zoom: CGFloat, scrollYPt: CGFloat) -> [TornEdge] {
        guard zoom.isFinite, zoom > 0 else { return [] }
        let offset = max(0, (viewport.width - contentWidthPt * zoom) / 2)
        var result: [TornEdge] = []
        for lower in frames where lower.sourceTopPt > 0 {
            guard let upper = frames.first(where: {
                $0.index == lower.index && $0.sourceTopPt == 0
                    && abs($0.sourceRangePt.upperBound - lower.sourceTopPt) < 0.01
            }), lower.topPt > upper.topPt + upper.heightPt else { continue }
            let left = offset + lower.leftPt * zoom
            let width = lower.widthPt * zoom
            let gap = (lower.topPt - upper.topPt - upper.heightPt) * zoom
            let depth = min(1.6, gap / 5)
            let count = max(2, Int(ceil(width / max(5, min(12, 7 * zoom)))))
            for (contentY, direction) in [(upper.topPt + upper.heightPt, CGFloat(1)),
                                           (lower.topPt, CGFloat(-1))] {
                let baseline = (contentY - scrollYPt) * zoom
                guard baseline > -20, baseline < viewport.height + 20 else { continue }
                let points = (0...count).map { i -> CGPoint in
                    let irregularity = CGFloat((i * 37 + lower.index * 13) % 11) / 10
                    let toothDepth: CGFloat = i == 0 || i == count ? 0 : depth * (0.25 + irregularity * 0.75)
                    return CGPoint(x: left + width * CGFloat(i) / CGFloat(count),
                                   y: baseline + direction * toothDepth)
                }
                result.append(TornEdge(points: points, baseline: baseline))
            }
        }
        return result
    }

}

/// A transparent layer above Metal, below annotations. Its shadow is masked out of paper interiors.
package final class PageChromeOverlayView: NSView {
    package private(set) var pageRectangles: [CGRect] = []
    private let edges = CAShapeLayer()
    private let shadows = CALayer()
    private let outsidePaper = CAShapeLayer()
    private let tornEdges = CAShapeLayer()
    override package var isFlipped: Bool { true }
    override package func hitTest(_ point: NSPoint) -> NSView? { nil }

    override package init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = true
        edges.fillColor = nil
        outsidePaper.fillRule = .evenOdd
        shadows.mask = outsidePaper
        layer?.addSublayer(shadows)
        layer?.addSublayer(edges)
        layer?.addSublayer(tornEdges)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    package func update(frames: [PagePlacement], contentWidthPt: CGFloat, zoom: CGFloat,
                        scrollYPt: CGFloat, scale: CGFloat) {
        let rects = PageChromeGeometry.rectangles(frames: frames, viewport: bounds.size,
            contentWidthPt: contentWidthPt, zoom: zoom, scrollYPt: scrollYPt)
        pageRectangles = rects
        let lineWidth = 1 / max(1, scale)
        let edgePath = CGMutablePath()
        let paperPath = CGMutablePath()
        let maskPath = CGMutablePath()
        maskPath.addRect(bounds.insetBy(dx: -20, dy: -20))
        for rect in rects {
            // The stroke is outside the source pixels, never on top of text or image content.
            edgePath.addRect(rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
            paperPath.addRect(rect)
            maskPath.addRect(rect)
        }
        let tearPath = CGMutablePath()
        for edge in PageChromeGeometry.tornEdges(frames: frames, viewport: bounds.size,
            contentWidthPt: contentWidthPt, zoom: zoom, scrollYPt: scrollYPt) {
            guard let first = edge.points.first, let last = edge.points.last else { continue }
            tearPath.move(to: first)
            for point in edge.points.dropFirst() { tearPath.addLine(to: point) }
            tearPath.addLine(to: CGPoint(x: last.x, y: edge.baseline))
            tearPath.addLine(to: CGPoint(x: first.x, y: edge.baseline))
            tearPath.closeSubpath()
        }
        var edgeColor = NSColor.clear.cgColor
        var tearColor = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            edgeColor = LyraReaderTheme.pageEdgeColor.cgColor
            tearColor = LyraReaderTheme.accentColor.withAlphaComponent(0.48).cgColor
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [edges, shadows, outsidePaper, tornEdges] { item.frame = bounds; item.contentsScale = scale }
        edges.path = edgePath
        edges.strokeColor = edgeColor
        edges.lineWidth = lineWidth
        shadows.shadowPath = paperPath
        shadows.shadowColor = (dark ? NSColor.black : NSColor(srgbRed: 48/255, green: 43/255, blue: 37/255, alpha: 1)).cgColor
        shadows.shadowOpacity = dark ? 0.28 : 0.12
        shadows.shadowRadius = 7
        shadows.shadowOffset = CGSize(width: 0, height: 3)
        outsidePaper.path = maskPath
        tornEdges.path = tearPath
        tornEdges.strokeColor = tearColor
        tornEdges.fillColor = edgeColor.copy(alpha: dark ? 0.24 : 0.16)
        tornEdges.lineWidth = lineWidth
        tornEdges.shadowPath = tearPath
        tornEdges.shadowColor = NSColor.black.cgColor
        tornEdges.shadowOpacity = dark ? 0.16 : 0.08
        tornEdges.shadowRadius = 1.5
        tornEdges.shadowOffset = .zero
        CATransaction.commit()
    }
}
