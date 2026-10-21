import CoreGraphics
import Foundation

/// One horizontal tear in a page's display, with the card's gap between the two pieces.
///
/// The tear is a **display/layout** fact, not a change to the page or its raster:
///
/// * `splitPt` is page-local content-space Y (0 at the page's top, PDF points). The paper above
///   it is the top segment and the paper below it is the bottom segment.
/// * `gapPt` is the height of the empty band between the segments in content points. It is the
///   card's measured height divided by the zoom, so the card fills it exactly.
/// * Neither segment loses a pixel. The page raster (or each tile) is drawn once and clipped by
///   the quad's source rectangle; the bottom segment's quads move down by `gapPt`. Nothing is
///   re-rasterized from PDFium because the page's pixels did not change.
///
/// A page has at most one tear at a time, because the reader has at most one open region card.
/// The type itself supports any number; the placement and the canvas allow one per page.
public struct PageTear: Equatable, Sendable {
    /// 0-based page index, like every other page index in the shell.
    public let page: Int
    /// Page-local Y where the paper is cut. Must be inside the page.
    public let splitPt: CGFloat
    /// Height of the gap between the segments, in content points.
    public let gapPt: CGFloat

    public init(page: Int, splitPt: CGFloat, gapPt: CGFloat) {
        self.page = page
        self.splitPt = splitPt
        self.gapPt = gapPt
    }
}

/// Where a region card's gap goes: cut inside the page, or after the page as before.
///
/// ``PageTearPlacement/plan(pageHeightPt:selection:gapPt:textPage:figures:)`` is the one rule;
/// the card, the layout and the checks all read its answer.
public struct PageTearPlan: Equatable, Sendable {
    public enum Anchor: Equatable, Sendable {
        /// Cut the page at this page-local Y; the card is the gap between the pieces.
        case insidePage(splitPt: CGFloat)
        /// The legacy placement: the card after the page's row, no cut.
        case pageFoot
    }

    public let anchor: Anchor
    /// Why the inside-page placement was refused, when it was. The card reports it; the layout
    /// still works (the card falls back to the page foot).
    public let fallbackReason: String?

    public init(anchor: Anchor, fallbackReason: String? = nil) {
        self.anchor = anchor
        self.fallbackReason = fallbackReason
    }

    public var splitPt: CGFloat? {
        if case .insidePage(let y) = anchor { return y }
        return nil
    }
}

/// The placement rule for a region card's tear.
///
/// **The exact rule.** Let `H` be the page height, `b` the selection's bottom edge, `g` the
/// card's gap, and `F` the page's figure/table regions (the artwork-plus-caption boxes from the
/// document's caption index).
///
/// 1. If `H - b < g` — the part of the page below the selection is shorter than the card — no
///    inside-page tear can satisfy the rule; the card falls back to the page foot.
/// 2. A selection with no text at all is a picture, a rule or a table the text layer cannot
///    describe. If the figure/table index names no region on this page either, the card falls
///    back to the page foot rather than cut through artwork it cannot see.
/// 3. Candidate Y positions, in increasing order, are `b`, then the bottom edge of every text
///    line that ends below `b`, then `H`.
/// 4. The first candidate that (a) is at or below `b` (never through the selected region),
///    (b) is not strictly inside a figure/table box, and (c) still leaves at least `g` points of
///    page below it is the tear. Condition (c) repeats the fit check for the candidate, so a
///    line bottom close to the page foot cannot sneak in.
/// 5. If no candidate qualifies, the card falls back to the page foot. The page is never cut
///    through a figure/table, and no tear is ever shorter than the card.
///
/// Step 3 is what "the nearest sensible point below the selection" means in practice: `b` is
/// used when it is already whitespace (a drag ending between lines), otherwise the tear moves
/// to the bottom of the line the selection ends in, leaving that line whole above the card.
public enum PageTearPlacement {
    public static func plan(
        pageHeightPt: CGFloat,
        selection: CGRect,
        gapPt: CGFloat,
        textPage: TextPage?,
        figures: [Figure] = [],
        selectionHasText: Bool = true
    ) -> PageTearPlan {
        guard pageHeightPt.isFinite, pageHeightPt > 1,
              selection.minY.isFinite, selection.maxY.isFinite else {
            return PageTearPlan(anchor: .pageFoot,
                                fallbackReason: "The page's geometry is not known.")
        }
        let height = pageHeightPt
        let bottom = min(max(0, selection.maxY), height)
        let gap = gapPt.isFinite ? max(0, gapPt) : 0
        guard bottom > 0.01, height - bottom > 0.01 else {
            return PageTearPlan(anchor: .pageFoot)
        }
        if gap >= height {
            return PageTearPlan(
                anchor: .pageFoot,
                fallbackReason: "The card is taller than the page, so it sits below the page instead of cutting it."
            )
        }
        guard height - bottom >= gap else {
            return PageTearPlan(
                anchor: .pageFoot,
                fallbackReason: "The part of the page below the selection is shorter than the card, so the card sits below the page instead of cutting it."
            )
        }

        let boxes = figures.filter { $0.page >= 0 && $0.widthPt > 1 && $0.heightPt > 1 }
            .map { CGRect(x: $0.xPt, y: $0.yPt, width: $0.widthPt, height: $0.heightPt) }
        // A non-blank selection with no text is a picture, a rule or a table the text layer
        // cannot describe. If the caption index does not name it either, cutting there would be
        // a guess; the card falls back to the page foot instead.
        if !selectionHasText, boxes.isEmpty {
            return PageTearPlan(
                anchor: .pageFoot,
                fallbackReason: "The selection contains no text and no figure or table region is indexed, so the card sits below the page rather than cutting through artwork."
            )
        }
        let lineBottoms = textLineBottoms(textPage?.chars ?? [])

        var candidates: [CGFloat] = [bottom]
        candidates.append(contentsOf: lineBottoms.filter { $0 > bottom + 0.01 })
        candidates.append(height)

        for raw in candidates {
            let y = min(height, max(bottom, raw))
            guard y > 0.01, y < height - 0.01 else { continue }
            guard height - y >= gap else {
                // Candidates only move down, so nothing later can fit either.
                return PageTearPlan(
                    anchor: .pageFoot,
                    fallbackReason: "The part of the page below the nearest whitespace is shorter than the card, so the card sits below the page instead of cutting it."
                )
            }
            if boxes.contains(where: { y > $0.minY + 0.01 && y < $0.maxY - 0.01 }) {
                continue
            }
            if crossesGlyph(at: y, chars: textPage?.chars ?? []) {
                continue
            }
            return PageTearPlan(anchor: .insidePage(splitPt: y))
        }
        return PageTearPlan(anchor: .pageFoot)
    }

    /// Bottom edges of the page's text lines, merged by vertical overlap and sorted.
    ///
    /// A glyph's own box is not a line: a superscript sits above the baseline, a descender below
    /// it. Merging boxes that overlap vertically (with a sub-point tolerance) reconstructs the
    /// line a reader sees, so its bottom is real whitespace rather than the bottom of one glyph.
    static func textLineBottoms(_ chars: [TextChar]) -> [CGFloat] {
        var bands: [(minY: CGFloat, maxY: CGFloat)] = []
        for char in chars.sorted(by: { $0.yPt < $1.yPt }) {
            guard char.widthPt > 0, char.heightPt > 0,
                  char.yPt.isFinite, char.heightPt.isFinite else { continue }
            let minY = char.yPt
            let maxY = char.yPt + char.heightPt
            if let index = bands.lastIndex(where: { minY <= $0.maxY + 0.75 }) {
                bands[index].minY = min(bands[index].minY, minY)
                bands[index].maxY = max(bands[index].maxY, maxY)
            } else {
                bands.append((minY, maxY))
            }
        }
        return bands.map(\.maxY).sorted()
    }

    /// Whether a horizontal cut at `y` would pass through a glyph.
    ///
    /// Zero-height contact (the top or bottom edge of a line) is not a cut: the line is wholly
    /// on one side of the tear.
    static func crossesGlyph(at y: CGFloat, chars: [TextChar]) -> Bool {
        chars.contains { char in
            guard char.heightPt > 0 else { return false }
            return char.yPt < y - 0.01 && char.yPt + char.heightPt > y + 0.01
        }
    }
}

/// Turns the unsplit draw list into the two display segments of a torn page.
///
/// This is the **only** place a page's pixels are clipped for a tear, and it deliberately works
/// on the texture quads the canvas already has:
///
/// * a quad wholly above the split is unchanged;
/// * a quad wholly below it moves down by `gapPt`;
/// * a quad crossing it becomes two quads with a source (UV) rectangle each — the same texture,
///   the same `PageImage.generation`, the same placement index, so the canvas uploads the page
///   bitmap once and draws it twice.
///
/// Tiles, page rasters, selection highlights, annotation quads and note glyphs all travel through
/// here, which is why a selection spanning the tear is clipped correctly without a second path.
package enum PageTearRendering {
    /// Splits one canvas quad. `pageTopPt` is the page's displayed top (gaps from earlier pages
    /// included); `pageLeftPt`/`pageWidthPt` identify the page so a facing partner's quads, which
    /// share the same top, are not clipped by this page's tear.
    package static func quads(
        for page: CanvasPage,
        pageTopPt: CGFloat,
        pageLeftPt: CGFloat,
        pageWidthPt: CGFloat,
        pageHeightPt: CGFloat,
        tear: PageTear
    ) -> [CanvasPage] {
        guard tear.gapPt > 0.01, pageHeightPt > 1 else { return [page] }
        let placement = page.placement
        // A quad belongs to the page when it starts inside its column. Everything this reader
        // draws for a page starts at or inside the page's left edge; a facing partner starts a
        // whole page-width away.
        guard placement.leftPt >= pageLeftPt - 1,
              placement.leftPt < pageLeftPt + pageWidthPt - 0.5 else {
            return [page]
        }
        let localTop = placement.topPt - pageTopPt
        let localBottom = localTop + placement.heightPt
        let split = min(max(tear.splitPt, 0), pageHeightPt)
        guard split > 0.01, split < pageHeightPt - 0.01, placement.heightPt > 0.01 else {
            return [page]
        }

        // Wholly above the tear.
        if localBottom <= split + 0.001 { return [page] }

        // Wholly below it: move the quad down, keep the whole source image.
        if localTop >= split - 0.001 {
            return [CanvasPage(
                placement: PagePlacement(
                    index: placement.index,
                    topPt: placement.topPt + tear.gapPt,
                    leftPt: placement.leftPt,
                    widthPt: placement.widthPt,
                    heightPt: placement.heightPt
                ),
                image: page.image,
                blend: page.blend,
                source: page.source
            )]
        }

        // Crossing it: two pieces, each carrying its own normalized source rectangle. The top
        // piece keeps the quad's top; the bottom piece starts after the gap and shows exactly
        // the rest of the source.
        let topHeight = split - localTop
        let bottomHeight = localBottom - split
        guard topHeight > 0.01, bottomHeight > 0.01 else { return [page] }
        let fraction = topHeight / placement.heightPt
        let source = page.source
        let topSource = CGRect(
            x: source.minX,
            y: source.minY,
            width: source.width,
            height: source.height * fraction
        )
        let bottomSource = CGRect(
            x: source.minX,
            y: source.minY + source.height * fraction,
            width: source.width,
            height: source.height * (1 - fraction)
        )
        return [
            CanvasPage(
                placement: PagePlacement(
                    index: placement.index,
                    topPt: placement.topPt,
                    leftPt: placement.leftPt,
                    widthPt: placement.widthPt,
                    heightPt: topHeight
                ),
                image: page.image,
                blend: page.blend,
                source: topSource
            ),
            CanvasPage(
                placement: PagePlacement(
                    index: placement.index,
                    topPt: pageTopPt + split + tear.gapPt,
                    leftPt: placement.leftPt,
                    widthPt: placement.widthPt,
                    heightPt: bottomHeight
                ),
                image: page.image,
                blend: page.blend,
                source: bottomSource
            ),
        ]
    }

    /// The whole draw list for a torn page, leaving every other quad alone.
    package static func quads(
        for pages: [CanvasPage],
        pageTopPt: CGFloat,
        pageLeftPt: CGFloat,
        pageWidthPt: CGFloat,
        pageHeightPt: CGFloat,
        tear: PageTear
    ) -> [CanvasPage] {
        pages.flatMap {
            quads(for: $0, pageTopPt: pageTopPt, pageLeftPt: pageLeftPt,
                  pageWidthPt: pageWidthPt, pageHeightPt: pageHeightPt, tear: tear)
        }
    }
}
