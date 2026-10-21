import CoreGraphics
import Foundation

/// AppState's half of the inside-page tear: which page is torn, where its segments are, and the
/// piecewise page ↔ content conversions every pointer path must use.
///
/// A tear never changes a page's own raster or the engine's layout. The page keeps its top and
/// its paper height; the display block grows by the card's gap, the bottom segment is drawn
/// below the gap, and every page in a later row moves down by the same amount. The helpers here
/// are the one place that arithmetic is spelled out, so a click above the tear, a click below it,
/// a selection that spans it and an annotation written under it cannot disagree.
extension AppState {
    /// The tears currently open, keyed by page. One open card means at most one tear; the
    /// dictionary shape keeps the layout code honest if that ever changes.
    var activePageTears: [Int: PageTear] {
        var tears: [Int: PageTear] = [:]
        for card in regionCards {
            guard let split = card.tearSplitPt,
                  split.isFinite, split > 0 else { continue }
            let gap = regionGapHeightPt(card)
            guard gap.isFinite, gap > 0.01 else { continue }
            tears[card.attachment.page] = PageTear(
                page: card.attachment.page,
                splitPt: split,
                gapPt: gap
            )
        }
        return tears
    }

    /// The tear on one page, if it is open.
    public func pageTear(forPage page: Int) -> PageTear? {
        activePageTears[page]
    }

    /// A page's paper size in points. The placement carries it whenever the page is in the
    /// visible band; otherwise the first page's size is the only synchronous answer the shell
    /// has, and a mismatch only affects a fallback layout decision, never a capture.
    func pageSizePt(forPage page: Int) -> CGSize {
        if let placement = pagePlacementForGeometry(page) {
            return CGSize(width: placement.widthPt, height: placement.heightPt)
        }
        if let document { return document.firstPageSize }
        return .zero
    }

    /// The page's display geometry: top with the gaps of earlier rows applied, and its paper
    /// rect (height excludes the tear's gap).
    func pageGeometry(forPage page: Int) -> PagePlacement? {
        guard let base = pagePlacementForGeometry(page) else { return nil }
        return PagePlacement(
            index: page,
            topPt: displayPageTop(page),
            leftPt: base.leftPt,
            widthPt: base.widthPt,
            heightPt: base.heightPt
        )
    }

    private func pagePlacementForGeometry(_ page: Int) -> PagePlacement? {
        if let visible = visiblePagePlacements.first(where: { $0.index == page }) {
            return visible
        }
        guard document != nil else { return nil }
        // A page just outside the prefetch band still has a placement in the engine's layout;
        // asking for a very wide window is the supported way to name it without inventing a
        // second copy of the page-size table in the shell.
        let top = displayPageTop(page)
        return engine.visiblePages(
            scrollYPt: top,
            viewportHeightPt: 1,
            gapPt: pageGapPt,
            marginPt: 1_000_000,
            layout: layoutMode
        ).first { $0.index == page }
    }

    /// The page's **display segments**. An untorn page is one segment identical to its page
    /// placement. A torn page is two placements: the paper above the split and the paper below
    /// it, the second moved down by the gap. `sourceTopPt`/`sourceHeightPt` say which part of
    /// the page each segment shows.
    public func pageSegments(for placement: PagePlacement) -> [PagePlacement] {
        let page = placement.index
        guard let tear = pageTear(forPage: page), tear.gapPt > 0.01 else {
            return [PagePlacement(
                index: placement.index,
                topPt: placement.topPt,
                leftPt: placement.leftPt,
                widthPt: placement.widthPt,
                heightPt: placement.heightPt,
                sourceTopPt: 0,
                sourceHeightPt: placement.heightPt
            )]
        }
        let height = placement.heightPt
        let split = min(max(tear.splitPt, 0.01), height - 0.01)
        guard split > 0.01, height - split > 0.01 else { return [placement] }
        let topPt = displayPageTop(page)
        return [
            PagePlacement(
                index: page,
                topPt: topPt,
                leftPt: placement.leftPt,
                widthPt: placement.widthPt,
                heightPt: split,
                sourceTopPt: 0,
                sourceHeightPt: split
            ),
            PagePlacement(
                index: page,
                topPt: topPt + split + tear.gapPt,
                leftPt: placement.leftPt,
                widthPt: placement.widthPt,
                heightPt: height - split,
                sourceTopPt: split,
                sourceHeightPt: height - split
            ),
        ]
    }

    /// The segments of one page by index, even when the page is outside the visible band (used
    /// by view-space conversions and the checks).
    public func pageSegments(forPage page: Int) -> [PagePlacement] {
        guard let geometry = pageGeometry(forPage: page) else { return [] }
        return pageSegments(for: geometry)
    }

    /// Every visible page's segments, in reading order. This is what the canvas, the page
    /// chrome and the annotation overlay receive: two entries for a torn page, one otherwise.
    package var canvasPageSegments: [PagePlacement] {
        visiblePagePlacements.flatMap { pageSegments(for: $0) }
    }

    /// The page under a **content point**, with the point in its page-local space.
    ///
    /// The implementation lives on the core `AppState` (`pagePoint(atContentPoint:)`), next to
    /// the other pointer paths, and reads `canvasPageSegments`.
    ///
    /// Content Y of a page-local Y, with the tear's gap applied below the split.
    ///
    /// Returns nil only for an unknown page. A Y outside the paper is still mapped (the caller's
    /// rectangle clipping decides what to do); this function never silently clamps, because a
    /// clamped answer would put an annotation in the wrong place.
    public func contentY(forPageLocalY y: CGFloat, onPage page: Int) -> CGFloat? {
        guard y.isFinite, let geometry = pageGeometry(forPage: page) else { return nil }
        let top = geometry.topPt
        if let tear = pageTear(forPage: page), y >= tear.splitPt {
            return top + y + tear.gapPt
        }
        return top + y
    }

    /// Page-local Y of a content Y, or nil when the content Y falls in the tear's gap.
    public func pageLocalY(forContentY y: CGFloat, onPage page: Int) -> CGFloat? {
        guard y.isFinite, let geometry = pageGeometry(forPage: page) else { return nil }
        let relative = y - geometry.topPt
        guard relative >= -0.001 else { return nil }
        if let tear = pageTear(forPage: page) {
            if relative >= tear.splitPt + tear.gapPt {
                return relative - tear.gapPt
            }
            if relative >= tear.splitPt {
                return nil
            }
        }
        return relative
    }

    /// The page-local Y band a content-space band covers, clipped to the displayed paper.
    ///
    /// For a torn page the two segments are disjoint in content space; the band is the union of
    /// what each contributes. The tile scheduler uses this to name rows, so it asks the page
    /// for page-local rows instead of assuming the display starts at the paper top.
    func pageLocalBand(top: CGFloat, bottom: CGFloat,
                       for placement: PagePlacement) -> ClosedRange<CGFloat>? {
        let height = placement.heightPt
        guard height > 1, bottom > top else { return nil }
        guard let tear = pageTear(forPage: placement.index), tear.gapPt > 0.01 else {
            let low = max(0, top - placement.topPt)
            let high = min(height, bottom - placement.topPt)
            return high > low ? low...high : nil
        }
        let pageTop = displayPageTop(placement.index)
        let split = min(max(tear.splitPt, 0.01), height - 0.01)
        let topSegment = pageTop..<(pageTop + split)
        let bottomStart = pageTop + split + tear.gapPt
        let bottomSegment = bottomStart..<(pageTop + height + tear.gapPt)
        var locals: [CGFloat] = []
        let topIntersection = (max(top, topSegment.lowerBound), min(bottom, topSegment.upperBound))
        if topIntersection.0 < topIntersection.1 {
            locals.append(topIntersection.0 - pageTop)
            locals.append(topIntersection.1 - pageTop)
        }
        let bottomIntersection = (max(top, bottomSegment.lowerBound),
                                  min(bottom, bottomSegment.upperBound))
        if bottomIntersection.0 < bottomIntersection.1 {
            locals.append(bottomIntersection.0 - bottomStart + split)
            locals.append(bottomIntersection.1 - bottomStart + split)
        }
        guard let low = locals.min(), let high = locals.max(), high > low else { return nil }
        return max(0, low)...min(height, high)
    }

    /// A page-local rectangle in view space, split at the tear when one is open.
    ///
    /// A rectangle wholly on one side returns one rectangle; one crossing the tear returns two,
    /// with the card's gap between them. The union form is what panel anchors and highlight
    /// bounds use; the array form is what the region marquee draws.
    public func viewRects(local region: CGRect, onPage page: Int) -> [CGRect] {
        let segments = pageSegments(forPage: page)
        guard !segments.isEmpty else { return [] }
        return CanvasGeometry.viewRects(
            pageSegments: segments,
            region: region,
            scrollYPt: scrollYPt,
            zoom: zoomFactor,
            contentOffsetX: CanvasGeometry.contentOffsetX(
                viewportWidthPt: viewportSizePt.width,
                contentWidthPt: contentWidthPt,
                zoom: zoomFactor
            )
        )
    }

    /// The single view-space rectangle for a page-local rect: the union of its segment rects.
    public func viewRect(local region: CGRect, onPage page: Int) -> CGRect? {
        let rects = viewRects(local: region, onPage: page)
        guard var union = rects.first else { return nil }
        for rect in rects.dropFirst() { union = union.union(rect) }
        return union
    }

    /// Splits the canvas draw list at the open tear. Called once, on the final list: page
    /// rasters, tiles, selection tints, annotation quads and note glyphs all arrive here, so a
    /// selection or an annotation crossing the tear is clipped exactly like the page itself.
    func applyPageTears(to pages: [CanvasPage]) -> [CanvasPage] {
        let tears = activePageTears
        guard !tears.isEmpty else { return pages }
        var result = pages
        for tear in tears.values {
            guard let geometry = pageGeometry(forPage: tear.page) else { continue }
            result = PageTearRendering.quads(
                for: result,
                pageTopPt: geometry.topPt,
                pageLeftPt: geometry.leftPt,
                pageWidthPt: geometry.widthPt,
                pageHeightPt: geometry.heightPt,
                tear: tear
            )
        }
        return result
    }
}
