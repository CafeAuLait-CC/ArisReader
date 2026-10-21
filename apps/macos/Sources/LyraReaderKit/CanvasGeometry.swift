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
/// The `zoom` every function takes is `AppState.zoomFactor`, not the bare percentage: it already
/// includes the display calibration, so at 100% one PDF point occupies `calibration × backing`
/// device pixels (see ``DisplayCalibration``).
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

    /// Content point under a view-space point (top-left origin).
    ///
    /// This is the inverse of ``viewRect(pageTopPt:pageLeftPt:region:scrollYPt:zoom:contentOffsetX:)``
    /// for a single point, and the conversion the canvas applies at its event boundary before
    /// any annotation, selection or redaction geometry sees it. Both directions live here so the
    /// pointer path cannot drift from the drawing path.
    ///
    /// `zoom` is the calibrated factor (`zoomFactor`), so a view point maps to the same page
    /// coordinate at 100%, 150% or any other percentage the reader chose.
    public static func contentPoint(
        viewX: CGFloat,
        viewYTop: CGFloat,
        scrollYPt: CGFloat,
        zoom: CGFloat,
        contentOffsetX: CGFloat
    ) -> CGPoint {
        let scale = max(zoom, 0.01)
        return CGPoint(
            x: (viewX - contentOffsetX) / scale,
            y: viewYTop / scale + scrollYPt
        )
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

    /// A page's full quad in **device pixels**, exactly as the Metal surface receives it.
    ///
    /// `zoom` is `AppState.zoomFactor`, which already contains the display calibration; the only
    /// other factor here is the drawing surface's backing scale. Calibration therefore appears
    /// **once** in `pageWidthPt × zoom × backingScale` — the renderer must not multiply it in
    /// again, and this shared function is what the renderer and the native zoom checks call.
    public static func pageRectInDevicePixels(
        pageTopPt: CGFloat,
        pageLeftPt: CGFloat,
        widthPt: CGFloat,
        heightPt: CGFloat,
        scrollYPt: CGFloat,
        zoom: CGFloat,
        backingScale: CGFloat,
        contentOffsetXPx: CGFloat
    ) -> CGRect {
        CGRect(
            x: contentOffsetXPx + pageLeftPt * zoom * backingScale,
            y: (pageTopPt - scrollYPt) * zoom * backingScale,
            width: widthPt * zoom * backingScale,
            height: heightPt * zoom * backingScale
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

    /// A placed-text glyph this reader wrote and keeps in its sidecar — a sticky note icon or a
    /// text box's laid-out text: one per annotation, downwards from `-7·block`. Capacity:
    /// 2^28 annotations. A block of its own, below `documentNote`, for the same reason that one
    /// has its own: the two kinds are drawn from different bitmaps and must not share a texture.
    public static func ownNote(_ index: Int) -> Int { -7 * block + index }

    /// Whether `index` names a sidecar placed-text glyph (a sticky note icon or a text box).
    public static func isOwnNote(_ index: Int) -> Bool {
        index >= -7 * block && index < -6 * block
    }

    /// The AI chat's transient source highlight: one box per line of the passage a citation
    /// chip points at, upwards from `-8·block`. Capacity: 2^28 boxes. It gets its own block so
    /// it can coexist with a selection without sharing a texture cache slot.
    public static func aiSource(_ index: Int) -> Int { -8 * block + index }

    /// Whether `index` names one box of the transient AI source highlight.
    public static func isAISource(_ index: Int) -> Bool {
        index >= -8 * block && index < -7 * block
    }

    /// A note glyph loaded from the PDF — a sticky icon, free text or inline-comment label:
    /// one per annotation, upwards from `-6·block`. Capacity: 2^28 notes.
    ///
    /// Below `documentAnnotation`'s base, which is the only room left: the blocks above are
    /// `documentAnnotation` (`[-5·block, -4·block)`), the page rasters (`[-4·block + 1, -3·block]`,
    /// growing *downwards* from `-3·block`), `ownAnnotation` and `selection`. It is a block of its
    /// own rather than one more `box` slot beside the markup quads because a note glyph is not a
    /// quad of a markup annotation: an annotation carrying both (a `/FreeText` with `/QuadPoints`
    /// is malformed but readable) would otherwise draw one of the two with the other's texture. One
    /// slot per annotation is enough: a markup comment has one label, while a standalone note
    /// is either an icon or free text.
    public static func documentNote(_ index: Int) -> Int { -6 * block + index }

    // The blocks above, as predicates. The native checks classify the quads they are handed with
    // these instead of by bitmap size, which stopped being a usable proxy the moment a free-text
    // annotation's text raster could be wider than a small page raster.

    /// Whether `index` names one box of the text-selection overlay.
    ///
    /// The overlay carries the ordinary blue selection when no tool is armed, and the live
    /// markup preview when one is; both are one quad per selected line in this block.
    public static func isSelection(_ index: Int) -> Bool {
        index >= -block && index < 0
    }

    /// Whether `index` names a whole-page raster (or a preview backdrop).
    ///
    /// Bounded at both ends: `pageRaster` grows downwards from `-3·block` for its whole documented
    /// capacity, so the last one it can reach is `-4·block + 1`.
    public static func isPageRaster(_ index: Int) -> Bool {
        index > -4 * block && index <= -3 * block
    }

    /// Whether `index` names one box of a markup annotation loaded from the PDF.
    public static func isDocumentAnnotationBox(_ index: Int) -> Bool {
        index >= -5 * block && index < -4 * block
    }

    /// Whether `index` names a note glyph, including an inline-comment label.
    public static func isDocumentNote(_ index: Int) -> Bool {
        index >= -6 * block && index < -5 * block
    }
}
