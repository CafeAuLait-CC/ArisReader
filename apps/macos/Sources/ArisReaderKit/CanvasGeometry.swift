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

/// The index blocks a `CanvasPage.placement.index` is partitioned into.
///
/// The index is not a label: `MetalCanvasView` caches each quad's GPU texture under it, so **two
/// quads in one frame must never share one** — the second upload replaces the first, and the
/// earlier quad is then drawn with the other one's bitmap. Measured 2026-10-15 on a review PDF:
/// a page raster and the first loaded highlight both landed on `-3_000_000_000`, so the
/// page-sized quad was painted with the highlight's 1x1 tint through the alpha-over pipeline — a
/// full-page wash of the highlight's colour with the text under it gone (the highlight itself was
/// composited correctly; the *page* had been handed the highlight's texture).
///
/// The blocks below cannot overlap for any document this reader can open: page rasters grow
/// *downwards* from their base, every overlay grows *upwards* inside its own block, and the blocks
/// are `block` indices apart. `placementIndexChecks` in the native suite asserts the partition,
/// capacity ends included.
///
/// Only the main reader canvas is partitioned here: the preview panel draws into its own
/// `MetalCanvasView`, which has its own texture cache, so its indices (`PreviewPanel`,
/// `referencePreviewPages`) cannot collide with these.
public enum PlacementIndex {
    /// Indices per block: 2^28. Page tiles and page rasters own everything above `-block`, so the
    /// overlays below cannot collide with them however a document is scrolled or zoomed.
    public static let block = 1 << 28

    /// A whole-page raster or preview backdrop: one per page, downwards from `-3·block`.
    /// Capacity: 2^28 pages.
    public static func pageRaster(_ page: Int) -> Int { -3 * block - page }

    /// The selection overlay: one box per selected line. Capacity: 2^28 boxes.
    public static func selection(_ index: Int) -> Int { -1 * block + index }

    /// An annotation this reader wrote and keeps in its sidecar. Capacity: 2^16 annotations.
    public static func ownAnnotation(_ index: Int) -> Int { -2 * block + index * 4_096 }

    /// A markup annotation loaded from the PDF: its position in `documentAnnotations` and which of
    /// its `/QuadPoints` boxes. Capacity: 2^18 annotations of 2^10 boxes each.
    ///
    /// Its own block, below the page rasters. The base it used to share with them (`-3·10⁹`) is
    /// the collision this type exists to prevent, and the 1024-index stride replaces a 16-index
    /// one that ran a 17-quad annotation into the next annotation's slot.
    public static func documentAnnotation(_ annotation: Int, box: Int) -> Int {
        -5 * block + annotation * 1_024 + box
    }
}
