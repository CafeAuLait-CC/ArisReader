import CoreGraphics
import Foundation

/// One comment attached to text markup, in page-local PDF points. Drawing, hit testing and
/// the expanded paper all use this same rectangle.
public struct InlineNoteMarker: Identifiable {
    public let id: String
    public let annotationIndex: Int
    public let page: Int
    public let rect: CGRect

    public static func layout(annotations: [DocumentAnnotation], textPages: [Int: TextPage]) -> [Self] {
        let size = CGSize(width: 24, height: 16)
        var occupied: [Int: [CGRect]] = [:]
        var markers: [Self] = []
        for (index, annotation) in annotations.enumerated() where annotation.hasInlineNote {
            let boxes = annotation.boxes.map {
                CGRect(x: $0.xPt, y: $0.yPt, width: $0.widthPt, height: $0.heightPt)
            }.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
            guard let first = boxes.min(by: {
                $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
            }) else { continue }
            // Put the label beside the text line, rather than beside a highlighted word in the
            // middle of it. Before the text layer arrives, the markup's left edge is a fallback.
            let line = textPages[annotation.page]?.lineBounds(overlapping: first)
            let left = line?.minX ?? boxes.map(\.minX).min() ?? first.minX
            var rect = CGRect(x: max(2, left - size.width - 6),
                              y: max(2, first.midY - size.height / 2),
                              width: size.width, height: size.height)
            // Comments on the same or adjacent lines get separate lanes in the margin. Keep
            // their Y aligned with the text while there is room to move sideways.
            while occupied[annotation.page, default: []].contains(where: {
                $0.insetBy(dx: -1, dy: -1).intersects(rect)
            }) {
                if rect.minX >= size.width + 4 {
                    rect.origin.x -= size.width + 4
                } else {
                    rect.origin.y += size.height + 4
                }
            }
            occupied[annotation.page, default: []].append(rect)
            markers.append(Self(id: annotation.id, annotationIndex: index,
                                page: annotation.page, rect: rect))
        }
        return markers
    }
}
