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
}

/// A transparent layer above Metal, below annotations. Its shadow is masked out of paper interiors.
package final class PageChromeOverlayView: NSView {
    private let edges = CAShapeLayer()
    private let shadows = CALayer()
    private let outsidePaper = CAShapeLayer()
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
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    package func update(frames: [PagePlacement], contentWidthPt: CGFloat, zoom: CGFloat,
                        scrollYPt: CGFloat, scale: CGFloat) {
        let rects = PageChromeGeometry.rectangles(frames: frames, viewport: bounds.size,
            contentWidthPt: contentWidthPt, zoom: zoom, scrollYPt: scrollYPt)
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
        var edgeColor = NSColor.clear.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            edgeColor = LyraReaderTheme.pageEdgeColor.cgColor
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [edges, shadows, outsidePaper] { item.frame = bounds; item.contentsScale = scale }
        edges.path = edgePath
        edges.strokeColor = edgeColor
        edges.lineWidth = lineWidth
        shadows.shadowPath = paperPath
        shadows.shadowColor = (dark ? NSColor.black : NSColor(srgbRed: 48/255, green: 43/255, blue: 37/255, alpha: 1)).cgColor
        shadows.shadowOpacity = dark ? 0.28 : 0.12
        shadows.shadowRadius = 7
        shadows.shadowOffset = CGSize(width: 0, height: 3)
        outsidePaper.path = maskPath
        CATransaction.commit()
    }
}
