import CoreGraphics

/// The canvas's view↔content mapping, spelled out once.
///
/// Two spaces are in play, and the whole point of this type is that they are named the same way
/// everywhere:
///
/// * **view space** — the canvas's own coordinate space with the origin at its **top-left**.
///   AppKit's is bottom-left; `MetalCanvasView` flips exactly once, at the event boundary, so
///   everything below the view's `bounds` uses this one.
/// * **content space** — PDF points with the origin at the top-left of the first page, Y growing
///   downwards. `PagePlacement` and `AppState.scrollYPt` live here.
///
/// The scroll path, the pointer-anchored zoom and the native checks all go through these
/// functions, so the anchoring arithmetic cannot drift from what the canvas draws.
public enum CanvasGeometry {
    /// Content Y under a view-space Y.
    public static func contentY(viewY: CGFloat, scrollYPt: CGFloat, zoom: CGFloat) -> CGFloat {
        viewY / max(zoom, 0.01) + scrollYPt
    }

    /// View-space Y of a content Y (the inverse of `contentY`).
    public static func viewY(contentY: CGFloat, scrollYPt: CGFloat, zoom: CGFloat) -> CGFloat {
        (contentY - scrollYPt) * zoom
    }

    /// The scroll offset that puts `contentY` back under `viewY` at a new zoom.
    ///
    /// This is the whole of pointer anchoring: the content point under the pointer is read at the
    /// old zoom, the zoom changes, and the offset is solved so that point lands at the same view
    /// position again. Only the vertical axis has state to solve for — see `contentOffsetX`.
    public static func scrollYPt(
        keepingContentY contentY: CGFloat,
        atViewY viewY: CGFloat,
        zoom: CGFloat
    ) -> CGFloat {
        contentY - viewY / max(zoom, 0.01)
    }

    /// Horizontal offset of the content inside the viewport.
    ///
    /// A document narrower than the viewport is centred; a wider one is clipped at its left edge.
    /// There is no horizontal scroll state to preserve, which is why a pointer-anchored zoom is
    /// exact vertically and best-effort horizontally: a point off to the right of a wide page
    /// cannot stay under the pointer while the canvas has nowhere to pan to.
    public static func contentOffsetX(
        viewportWidthPt: CGFloat,
        contentWidthPt: CGFloat,
        zoom: CGFloat
    ) -> CGFloat {
        max(0, (viewportWidthPt - contentWidthPt * zoom) / 2)
    }

    /// A page region in view space, ready to be drawn or measured against the viewport.
    public static func viewRect(
        pageTopPt: CGFloat,
        pageLeftPt: CGFloat,
        region: CGRect,
        scrollYPt: CGFloat,
        zoom: CGFloat,
        contentOffsetX: CGFloat
    ) -> CGRect {
        CGRect(
            x: contentOffsetX + (pageLeftPt + region.minX) * zoom,
            y: (pageTopPt + region.minY - scrollYPt) * zoom,
            width: region.width * zoom,
            height: region.height * zoom
        )
    }
}
