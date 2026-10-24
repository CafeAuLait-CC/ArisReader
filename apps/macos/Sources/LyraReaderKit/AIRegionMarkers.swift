import AppKit
import SwiftUI

/// Map the original captured rectangle through the same display segments as the PDF.
/// A selection crossing a tear produces two outlines; the gap itself is never tinted.
package enum AIRegionMarkerGeometry {
    package static func rectangles(attachment: AIRegionAttachment, frames: [PagePlacement],
                                   width: CGFloat, contentWidth: CGFloat,
                                   scroll: CGFloat, zoom: CGFloat) -> [CGRect] {
        guard zoom.isFinite, zoom > 0 else { return [] }
        let offset = max(0, (width - contentWidth * zoom) / 2)
        return frames.filter { $0.index == attachment.page }.compactMap { frame in
            let source = CGRect(x: 0, y: frame.sourceTopPt, width: frame.widthPt, height: frame.heightPt)
            let clipped = attachment.rect.intersection(source)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return CGRect(x: offset + (frame.leftPt + clipped.minX) * zoom,
                y: (frame.topPt + clipped.minY - frame.sourceTopPt - scroll) * zoom,
                width: clipped.width * zoom, height: clipped.height * zoom)
        }
    }
}

@MainActor
final class AIRegionMarkerButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    var regionID: UUID?
    var activate: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded; isBordered = false
        font = .systemFont(ofSize: 11, weight: .semibold)
        target = self; action = #selector(openConversation)
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        NSColor(LyraReaderTheme.accentSoft).setFill(); shape.fill()
        NSColor(LyraReaderTheme.accentBorder).withAlphaComponent(0.6).setStroke()
        shape.lineWidth = 1; shape.stroke()
        super.draw(dirtyRect)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func openConversation() { activate?(); window?.makeFirstResponder(self) }
}
