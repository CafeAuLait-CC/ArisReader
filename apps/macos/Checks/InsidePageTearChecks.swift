import AppKit
import Foundation
import LyraReaderKit

/// A synthetic three-page document whose text lines and raster pattern are known exactly.
///
/// The page is 600 × 1200 pt, every page has four text lines (100, 300, 500 and 1100), and the
/// raster is a distinct colour per row, so a segment's pixels can be compared with the unsplit
/// page without depending on a fixture's layout.
@MainActor
private final class TearLayoutEngine: PreviewEngine {
    let pageSize = CGSize(width: 600, height: 1200)
    let textLines: [(text: String, y: CGFloat)] = [
        ("Above line", 100), ("Middle line", 300), ("Below line", 500),
        ("Figure line", 700), ("Foot line", 1100),
    ]
    /// Set before opening the document to make the engine report a figure box; the placement
    /// rule then has to avoid it.
    var planningFigures: [Figure] = []
    private(set) var renderCalls: [Int: Int] = [:]
    private(set) var tileCalls: [Int: Int] = [:]
    private(set) var regionCalls: [Int: Int] = [:]
    private var generationCounter: UInt64 = 900

    override func openDocument(at url: URL) throws -> LoadedDocument {
        LoadedDocument(title: "Tear layout fixture", pageCount: 3, url: url,
                       firstPageSize: pageSize)
    }

    override func contentHeightPt(gapPt: CGFloat) -> CGFloat {
        3 * pageSize.height + 2 * max(0, gapPt)
    }

    override func contentWidthPt(gapPt: CGFloat) -> CGFloat { pageSize.width }

    override func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat {
        CGFloat(max(0, index)) * (pageSize.height + max(0, gapPt))
    }

    override func pageIndex(atScrollYPt y: CGFloat, gapPt: CGFloat) -> Int {
        let stride = pageSize.height + max(0, gapPt)
        return min(2, max(0, Int(floor(y / stride))))
    }

    override func visiblePages(scrollYPt: CGFloat, viewportHeightPt: CGFloat,
                               gapPt: CGFloat, marginPt: CGFloat) -> [PagePlacement] {
        let stride = pageSize.height + max(0, gapPt)
        return (0..<3).compactMap { index in
            let top = CGFloat(index) * stride
            guard top + pageSize.height >= scrollYPt - marginPt,
                  top <= scrollYPt + viewportHeightPt + marginPt else { return nil }
            return PagePlacement(index: index, topPt: top, leftPt: 0,
                                 widthPt: pageSize.width, heightPt: pageSize.height)
        }
    }

    override func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        renderCalls[page, default: 0] += 1
        let width = max(1, Int(ceil(pageSize.width * scale)))
        let height = max(1, Int(ceil(pageSize.height * scale)))
        generationCounter += 1
        return makeImage(pixelWidth: width, pixelHeight: height,
                         pointSize: pageSize, generation: generationCounter)
    }

    override func rasterizeTile(page: Int, lod: UInt8, tileX: Int, tileY: Int,
                                tileSize: Int) async throws -> TileImage {
        tileCalls[page, default: 0] += 1
        generationCounter += 1
        var bytes = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
        for y in 0..<tileSize {
            let row = UInt8((tileY * tileSize + y) & 0xFF)
            for x in 0..<tileSize {
                let offset = (y * tileSize + x) * 4
                bytes[offset] = row
                bytes[offset + 1] = UInt8((tileX * 3 + x) & 0xFF)
                bytes[offset + 2] = 9
                bytes[offset + 3] = 255
            }
        }
        return TileImage(page: page, lod: lod, tileX: tileX, tileY: tileY,
                         sizePx: tileSize, bgra: Data(bytes), generation: generationCounter)
    }

    override func rasterizeRegion(page: Int, scale: CGFloat, xPt: CGFloat, yPt: CGFloat,
                                  widthPt: CGFloat, heightPt: CGFloat,
                                  transparentBackground: Bool) async throws -> PageImage {
        regionCalls[page, default: 0] += 1
        let width = max(1, Int(ceil(widthPt * scale)))
        let height = max(1, Int(ceil(heightPt * scale)))
        generationCounter += 1
        return makeImage(pixelWidth: width, pixelHeight: height,
                         pointSize: CGSize(width: widthPt, height: heightPt),
                         generation: generationCounter)
    }

    override func textPage(_ page: Int) async throws -> LyraReaderKit.TextPage {
        var chars: [LyraReaderKit.TextChar] = []
        var whole = ""
        for (text, y) in textLines {
            var x: CGFloat = 100
            for scalar in text.unicodeScalars {
                chars.append(LyraReaderKit.TextChar(unicode: scalar.value, xPt: x, yPt: y,
                                                    widthPt: 7, heightPt: 11))
                x += 7
            }
            whole += text + "\n"
        }
        return LyraReaderKit.TextPage(page: page, chars: chars, text: whole,
                                      hasUnicodeMapError: false)
    }

    override func captionMentions(page: Int) async throws -> [CaptionMention] { [] }
    override func figures() async throws -> [Figure] { planningFigures }

    private func makeImage(pixelWidth: Int, pixelHeight: Int, pointSize: CGSize,
                           generation: UInt64) -> PageImage {
        var bytes = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        for y in 0..<pixelHeight {
            let blue = UInt8(y & 0xFF)
            let green = UInt8((y >> 8) & 0xFF)
            for x in 0..<pixelWidth {
                let offset = (y * pixelWidth + x) * 4
                bytes[offset] = blue
                bytes[offset + 1] = green
                bytes[offset + 2] = 12
                bytes[offset + 3] = 255
            }
        }
        return PageImage(pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                         pointSize: pointSize, bgra: Data(bytes), generation: generation)
    }
}

extension ReaderChecks {
    /// The tear that opens **inside** a page: the placement rule, the two display segments, the
    /// clipped pixels, piecewise geometry, selection and annotations across it, printing, and the
    /// explicit fallbacks.
    @MainActor
    static func insidePageTearChecks(root: URL) async throws {
        try await tearPlacementRuleChecks()
        try await tearLayoutChecks()
        try await tearPixelCompositionChecks()
        try await tearMappingChecks()
        try await tearSelectionChecks()
        try await tearRasterWorkChecks()
        try await tearFailureChecks()
        try await tearFitChecks()
        try await tearAnnotationChecks(root: root)
        try await tearPrintingChecks(root: root)
        try await tearPageEditChecks(root: root)
    }

    // MARK: - Helpers

    @MainActor
    private static func makeTearState(preferFullPageRasters: Bool = true,
                                      figures: [Figure] = []) -> (AppState, TearLayoutEngine) {
        let engine = TearLayoutEngine()
        engine.planningFigures = figures
        let state = AppState(engine: engine, preferFullPageRasters: preferFullPageRasters)
        state.setViewportSize(CGSize(width: 900, height: 700))
        guard state.open(url: URL(fileURLWithPath: "/tmp/lyra-inside-tear-\(UUID()).pdf")) else {
            fatalError("FAIL: the tear layout fixture opens")
        }
        state.reloadVisiblePages()
        return (state, engine)
    }

    @MainActor
    private static func openCard(_ state: AppState, rect: CGRect,
                                 measuredViewHeight: CGFloat? = nil) async throws -> AIRegionCard {
        await state.createRegionCard(page: 0, rect: rect)
        guard let card = state.regionCards.first else {
            fatalError("FAIL: the region card was refused: \(state.regionRefusalMessage ?? "no reason")")
        }
        if let measuredViewHeight {
            state.updateRegionCardHeight(cardID: card.id, viewHeight: measuredViewHeight)
        }
        state.reloadVisiblePages()
        return card
    }

    @MainActor
    private static func firstLineRect(_ text: LyraReaderKit.TextPage, pageHeight: CGFloat) -> CGRect {
        guard let first = text.chars.min(by: { $0.yPt < $1.yPt }) else {
            fatalError("FAIL: the fixture has text")
        }
        return CGRect(x: max(0, first.xPt - 8),
                      y: max(0, first.yPt - 4),
                      width: min(300, 600 - max(0, first.xPt - 8)),
                      height: max(14, first.heightPt + 8))
    }

    // MARK: - The placement rule

    @MainActor
    private static func tearPlacementRuleChecks() async throws {
        let text = try await TearLayoutEngine().textPage(0)
        func plan(_ selection: CGRect, gap: CGFloat, figures: [Figure] = [],
                  pageHeight: CGFloat = 1200) -> PageTearPlan {
            PageTearPlacement.plan(pageHeightPt: pageHeight, selection: selection,
                                   gapPt: gap, textPage: text, figures: figures)
        }

        let midPage = plan(CGRect(x: 100, y: 100, width: 220, height: 90), gap: 300)
        require(midPage.splitPt == 190,
                "a mid-page selection tears at its own bottom edge when the card fits below: \(String(describing: midPage.splitPt))")

        let throughGlyph = plan(CGRect(x: 100, y: 200, width: 220, height: 105), gap: 300)
        require(throughGlyph.splitPt == 311,
                "a bottom edge inside a text line moves to that line's bottom instead of cutting it: \(String(describing: throughGlyph.splitPt))")
        require((throughGlyph.splitPt ?? 0) > 0,
                "the tear is never placed above the selected region")

        let nearFoot = plan(CGRect(x: 100, y: 1000, width: 220, height: 100), gap: 300)
        require(nearFoot.splitPt == 1100,
                "a safe cut near the foot does not depend on the inserted conversation height")
        require(nearFoot.fallbackReason == nil, "a safe cut needs no fallback")

        let tallerThanPage = plan(CGRect(x: 100, y: 100, width: 220, height: 90), gap: 1400)
        require(tallerThanPage.splitPt == 190,
                "even a large inserted gap keeps the same safe paper cut")

        let figure = Figure(kind: "Figure", label: "1", page: 0, captionText: "A figure",
                            xPt: 40, yPt: 250, widthPt: 520, heightPt: 350)
        // A line at 700 is the first whitespace below the figure; the ordinary fixture's next
        // line is at 1100, which would leave less than the card below it.
        var figureChars: [LyraReaderKit.TextChar] = []
        for y in [300.0, 500.0, 700.0] {
            var x: CGFloat = 100
            for scalar in "Figure line".unicodeScalars {
                figureChars.append(LyraReaderKit.TextChar(unicode: scalar.value, xPt: x, yPt: y,
                                                          widthPt: 7, heightPt: 11))
                x += 7
            }
        }
        let figureText = LyraReaderKit.TextPage(page: 0, chars: figureChars, text: "",
                                                hasUnicodeMapError: false)
        let overFigure = PageTearPlacement.plan(
            pageHeightPt: 1200,
            selection: CGRect(x: 100, y: 100, width: 220, height: 200),
            gapPt: 300, textPage: figureText, figures: [figure])
        require(overFigure.splitPt == 711,
                "the tear skips a figure/table box and lands at the next whitespace: \(String(describing: overFigure.splitPt))")
        require((overFigure.splitPt ?? 0) > 600,
                "the tear is not inside the figure region (250…600)")

        let figureNoFit = PageTearPlacement.plan(
            pageHeightPt: 1200,
            selection: CGRect(x: 100, y: 100, width: 220, height: 200),
            gapPt: 500, textPage: figureText, figures: [figure])
        require(figureNoFit.splitPt == 711,
                "a larger gap stays below the figure at the same whitespace")

        let uncaptionedArtwork = PageTearPlacement.plan(
            pageHeightPt: 1200,
            selection: CGRect(x: 10, y: 100, width: 80, height: 100),
            gapPt: 300, textPage: nil, selectionHasText: false)
        require(uncaptionedArtwork.anchor == .pageFoot,
                "a non-blank selection with no text and no indexed figure/table falls back instead of cutting artwork")
        require(uncaptionedArtwork.fallbackReason?.contains("no figure or table") == true,
                "the artwork fallback says what was missing")

        let textlessPage = PageTearPlacement.plan(
            pageHeightPt: 1200,
            selection: CGRect(x: 10, y: 100, width: 80, height: 100),
            gapPt: 300, textPage: nil, figures: [
                Figure(kind: "Figure", label: "9", page: 0, captionText: "indexed",
                       xPt: 0, yPt: 600, widthPt: 100, heightPt: 100),
            ], selectionHasText: false)
        require(textlessPage.splitPt == 200,
                "an indexed figure elsewhere on the page lets a textless selection tear at its bottom edge")
    }

    // MARK: - Layout, segments and exact removal

    @MainActor
    private static func tearLayoutChecks() async throws {
        let (state, _) = makeTearState()
        try await eventually("the synthetic text layer loads") { state.hasTextLayer(0) }
        let page0Before = state.canvasPageFrames.first { $0.index == 0 }!
        let page1Before = state.canvasPageFrames.first { $0.index == 1 }!
        let heightBefore = state.contentHeightPt

        let card = try await openCard(state, rect: CGRect(x: 100, y: 100, width: 220, height: 90),
                                      measuredViewHeight: 300)
        require(card.tearSplitPt == 190,
                "the mid-page card tears page 0 at the selection's bottom edge: \(String(describing: card.tearSplitPt))")
        require(state.regionCards.count == 1, "one card at a time")

        let segments = state.pageSegments(forPage: 0)
        require(segments.count == 2, "a torn page is laid out as two display segments")
        let top = segments[0]
        let bottom = segments[1]
        require(abs(top.topPt - page0Before.topPt) < 0.001 && abs(top.heightPt - 190) < 0.001,
                "the top segment starts at the page top and shows exactly the content above the split")
        require(abs(bottom.sourceTopPt - 190) < 0.001 && abs(bottom.heightPt - 1010) < 0.001,
                "the bottom segment shows exactly the content below the split")
        let gapTop = state.regionGapTop(for: card.id)!
        require(abs(gapTop - 190) < 0.001, "the card's gap starts at the tear")
        require(abs(bottom.topPt - (gapTop + 300)) < 0.001,
                "the bottom segment starts after the card's gap")
        require(abs(page1Before.topPt + 300 - state.canvasPageFrames.first { $0.index == 1 }!.topPt) < 0.001,
                "everything after the torn page moves down by the card's height")
        require(abs(state.contentHeightPt - (heightBefore + 300)) < 0.001,
                "content height grows by the gap")

        try await eventually("the page is handed to the canvas as two clipped quads") {
            let quads = state.canvasPages.filter { $0.placement.index == PlacementIndex.pageRaster(0) }
            guard quads.count == 2 else { return false }
            return abs(quads[0].source.maxY - quads[1].source.minY) < 0.001
                && quads[0].image.generation == quads[1].image.generation
        }
        let quads = state.canvasPages.filter { $0.placement.index == PlacementIndex.pageRaster(0) }
        require(quads.count == 2,
                "the torn page's raster is one image drawn as two source-clipped quads")
        require(quads[0].image.generation == quads[1].image.generation,
                "both segments reuse the same raster generation (no second render)")
        require(abs(quads[0].placement.heightPt - 190) < 0.001
                && abs(quads[1].placement.topPt - (190 + 300)) < 0.001
                && abs(quads[1].placement.heightPt - 1010) < 0.001,
                "the two quads' destinations are the two segments, with the gap between them")
        let chrome = PageChromeGeometry.rectangles(
            frames: state.canvasPageSegments,
            viewport: CGSize(width: 900, height: 700),
            contentWidthPt: state.contentWidthPt,
            zoom: state.zoomFactor,
            scrollYPt: state.scrollYPt
        )
        require(chrome.count == 2,
                "page chrome draws two paper edges for the two segments (\(chrome.count))")
        require(chrome[1].minY > chrome[0].maxY,
                "the two chrome rectangles are separated by the card's gap")

        // Removal restores the exact layout.
        state.closeRegionCard(id: card.id, keepHistory: false)
        state.reloadVisiblePages()
        require(abs(state.canvasPageFrames.first { $0.index == 1 }!.topPt - page1Before.topPt) < 0.001,
                "closing the card restores the page below to its previous offset")
        require(abs(state.contentHeightPt - heightBefore) < 0.001,
                "closing the card restores the content height")
        require(state.pageSegments(forPage: 0).count == 1,
                "closing the card removes the tear, so the page is one segment again")

        // Scrolling while the card is open, then closing: the layout still restores exactly.
        let card2 = try await openCard(state, rect: CGRect(x: 100, y: 100, width: 220, height: 90),
                                       measuredViewHeight: 300)
        state.scroll(byScreenPoints: 600)
        state.reloadVisiblePages()
        state.closeRegionCard(id: card2.id, keepHistory: false)
        state.reloadVisiblePages()
        require(abs(state.canvasPageFrames.first { $0.index == 1 }!.topPt - page1Before.topPt) < 0.001,
                "closing after a scroll still restores the page offsets exactly")
        require(abs(state.contentHeightPt - heightBefore) < 0.001,
                "closing after a scroll still restores the content height")

        // 150%: the card is the same view height, so its content gap shrinks with the zoom, and
        // the bottom segment and every later page follow the new gap.
        state.zoomPercent = 150
        state.reloadVisiblePages()
        let heightAt150 = state.contentHeightPt
        let page1At150 = state.canvasPageFrames.first { $0.index == 1 }!.topPt
        let card3 = try await openCard(state, rect: CGRect(x: 100, y: 100, width: 220, height: 90),
                                       measuredViewHeight: 300)
        require(abs(state.regionGapHeightPt(card3) - 200) < 0.001,
                "at 150% the card's 300 view points are a 200 point gap")
        require(abs(state.canvasPageFrames.first { $0.index == 1 }!.topPt
                    - (page1At150 + 200)) < 0.001,
                "at 150% the page below moves by the new gap")
        require(abs(state.contentHeightPt - (heightAt150 + 200)) < 0.001,
                "at 150% content height grows by the new gap")
        require(state.pageSegments(forPage: 0).count == 2,
                "a zoom change keeps the tear on the same page")
        let beforeCloseAt150 = state.canvasPageFrames.first { $0.index == 1 }!.topPt
        state.closeRegionCard(id: card3.id, keepHistory: false)
        state.reloadVisiblePages()
        require(abs(state.canvasPageFrames.first { $0.index == 1 }!.topPt
                    - (beforeCloseAt150 - 200)) < 0.001,
                "at 150% closing restores the exact page offset")
        require(abs(state.contentHeightPt - heightAt150) < 0.001,
                "at 150% closing restores the exact content height")
    }

    // MARK: - Pixels

    @MainActor
    private static func tearPixelCompositionChecks() async throws {
        let pageWidth = 8
        let pageHeight = 12
        var bytes = [UInt8](repeating: 0, count: pageWidth * pageHeight * 4)
        for y in 0..<pageHeight {
            for x in 0..<pageWidth {
                let offset = (y * pageWidth + x) * 4
                bytes[offset] = UInt8(y * 10)       // distinct row colour
                bytes[offset + 1] = 20
                bytes[offset + 2] = 30
                bytes[offset + 3] = 255
            }
        }
        let image = PageImage(pixelWidth: pageWidth, pixelHeight: pageHeight,
                              pointSize: CGSize(width: pageWidth, height: pageHeight),
                              bgra: Data(bytes), generation: 7)
        let placement = PagePlacement(index: 0, topPt: 0, leftPt: 0,
                                      widthPt: CGFloat(pageWidth), heightPt: CGFloat(pageHeight))
        let tear = PageTear(page: 0, splitPt: 4, gapPt: 3)
        let quads = PageTearRendering.quads(
            for: CanvasPage(placement: placement, image: image),
            pageTopPt: 0, pageLeftPt: 0, pageWidthPt: CGFloat(pageWidth),
            pageHeightPt: CGFloat(pageHeight), tear: tear
        )
        require(quads.count == 2, "one quad crossing the tear becomes two pieces")

        func sourceRow(_ quad: CanvasPage, _ destRow: Int) -> Int {
            let fraction = quad.source.minY + (CGFloat(destRow) / quad.placement.heightPt) * quad.source.height
            return min(pageHeight - 1, max(0, Int((fraction * CGFloat(pageHeight)).rounded())))
        }
        func colour(_ row: Int) -> [UInt8] {
            let offset = row * pageWidth * 4
            return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
        }

        // 100%: every original row appears exactly once, above the gap or below it, and no pixel
        // of the selected page is missing or duplicated.
        var seen = Set<Int>()
        for row in 0..<pageHeight {
            let destRow: Int
            if row < 4 {
                destRow = row
                require(sourceRow(quads[0], destRow) == row,
                        "the top segment's row \(row) comes from the original row \(row)")
                require(colour(row) == colour(sourceRow(quads[0], destRow)),
                        "the top segment's pixels match the unsplit page at row \(row)")
            } else {
                destRow = row + 3
                let local = destRow - (4 + 3)
                require(sourceRow(quads[1], local) == row,
                        "the bottom segment's row \(row) comes from the original row \(row)")
                require(colour(row) == colour(sourceRow(quads[1], local)),
                        "the bottom segment's pixels match the unsplit page at row \(row)")
            }
            require(seen.insert(row).inserted, "original row \(row) appears exactly once")
        }
        require(seen.count == pageHeight, "no page row is lost")
        require(quads[0].placement.heightPt == 4 && quads[1].placement.topPt == 7
                && quads[1].placement.heightPt == 8,
                "the two quads cover exactly the two paper pieces, gap included")
        require(quads[0].image.generation == quads[1].image.generation,
                "both pieces show the same uploaded bitmap")

        // In facing layout the partner page shares the same top edge. The tear belongs to one
        // page's column, so the partner's quad must pass through untouched.
        let partner = CanvasPage(
            placement: PagePlacement(index: 1, topPt: 0, leftPt: 8,
                                     widthPt: 8, heightPt: 12),
            image: image
        )
        let both = PageTearRendering.quads(
            for: [CanvasPage(placement: placement, image: image), partner],
            pageTopPt: 0, pageLeftPt: 0, pageWidthPt: 8, pageHeightPt: 12, tear: tear
        )
        require(both.count == 3, "only the torn column is split in a facing row")
        require(both.contains { $0.placement.index == 1 && $0.placement.leftPt == 8
            && $0.source == CGRect(x: 0, y: 0, width: 1, height: 1) },
                "the facing partner page keeps its whole texture and position")

        // 150%: the same mapping, with each content point becoming 1.5 pixels.
        let zoom: CGFloat = 1.5
        let scaled = quads.map { quad -> CanvasPage in
            CanvasPage(placement: PagePlacement(
                index: quad.placement.index,
                topPt: quad.placement.topPt * zoom,
                leftPt: quad.placement.leftPt * zoom,
                widthPt: quad.placement.widthPt * zoom,
                heightPt: quad.placement.heightPt * zoom
            ), image: quad.image, blend: quad.blend, source: quad.source)
        }
        var covered = Set<Int>()
        for pixelRow in 0..<Int(CGFloat(pageHeight + 3) * zoom) {
            if pixelRow < Int(4 * zoom) {
                let source = sourceRow(scaled[0], pixelRow)
                require(source >= 0 && source < 4, "150% top pixel \(pixelRow) stays above the tear")
                covered.insert(source)
            } else if pixelRow >= Int(7 * zoom) {
                let source = sourceRow(scaled[1], pixelRow - Int(7 * zoom))
                require(source >= 4 && source < pageHeight,
                        "150% bottom pixel \(pixelRow) stays below the tear")
                covered.insert(source)
            }
        }
        require(covered.count == pageHeight,
                "at 150% every original row is still shown exactly once")
    }

    // MARK: - Piecewise mapping and hit testing

    @MainActor
    private static func tearMappingChecks() async throws {
        let (state, _) = makeTearState()
        try await eventually("the synthetic text layer loads") { state.hasTextLayer(0) }
        let card = try await openCard(state, rect: CGRect(x: 100, y: 100, width: 220, height: 90),
                                      measuredViewHeight: 300)
        require(card.tearSplitPt == 190, "mapping fixture tears at 190")

        let above = state.pagePoint(atContentPoint: CGPoint(x: 50, y: 100))
        require(above?.page == 0 && above?.point == CGPoint(x: 50, y: 100),
                "a point above the tear maps to its page Y")
        let belowContent = CGPoint(x: 50, y: 900 + 300)
        let below = state.pagePoint(atContentPoint: belowContent)
        require(below?.page == 0 && below?.point == CGPoint(x: 50, y: 900),
                "a point below the tear subtracts the gap and names the same page Y it had before the tear")
        require(state.pagePoint(atContentPoint: CGPoint(x: 50, y: 190 + 100)) == nil,
                "a point in the card's gap belongs to no page, like a gap between pages")
        require(state.pageIndex(at: CGPoint(x: 50, y: 190 + 100)) == nil,
                "page hit testing skips the gap")
        require(state.pageIndex(at: belowContent) == 0,
                "page hit testing finds the page below the tear")
        require(state.contentY(forPageLocalY: 100, onPage: 0) == 100,
                "page Y above the split maps to the page's content Y")
        require(state.contentY(forPageLocalY: 900, onPage: 0) == 1200,
                "page Y below the split adds the gap")
        require(state.pageLocalY(forContentY: 1200, onPage: 0) == 900,
                "content Y below the gap maps back to the page Y")
        require(state.pageLocalY(forContentY: 190 + 100, onPage: 0) == nil,
                "content Y inside the gap has no page Y")

        let segment = state.pagePlacement(at: belowContent)
        require(segment?.index == 0 && segment?.sourceTopPt == 190,
                "the bottom segment is a real placement with its page-local source offset")
        let rects = state.viewRects(local: CGRect(x: 10, y: 100, width: 100, height: 500), onPage: 0)
        require(rects.count == 2, "a page rectangle spanning the tear becomes two view rectangles")
        require(abs(rects[0].minY - 100) < 0.001 && abs(rects[0].height - 90) < 0.001,
                "the upper piece of the rectangle is above the tear")
        require(abs(rects[1].minY - (190 + 300)) < 0.001 && abs(rects[1].height - 410) < 0.001,
                "the lower piece starts after the gap and keeps the page-local offsets")

        state.reloadVisiblePages()
        require(state.currentPage == 1, "the page indicator names the torn page at the top")
        state.scroll(byScreenPoints: 160)
        state.reloadVisiblePages()
        require(state.currentPage == 1, "scrolling into the gap still names the torn page")
        state.scroll(byScreenPoints: 500)
        state.reloadVisiblePages()
        require(state.currentPage == 1, "scrolling into the bottom segment still names the torn page")
        state.scroll(byScreenPoints: 1200)
        state.reloadVisiblePages()
        require(state.currentPage == 2, "scrolling past the page names the next page")
    }

    // MARK: - Text selection spanning the tear

    @MainActor
    private static func tearSelectionChecks() async throws {
        let (state, _) = makeTearState()
        try await eventually("the synthetic text layer loads") { state.hasTextLayer(0) }
        state.beginSelection(at: CGPoint(x: 150, y: 305))
        state.extendSelection(to: CGPoint(x: 150, y: 505))
        guard let before = state.selection else {
            fatalError("FAIL: the fixture selection spans two text lines")
        }
        require(before.range.count > 10, "the pre-tear selection covers characters on both lines")

        let card = try await openCard(state, rect: CGRect(x: 100, y: 100, width: 220, height: 240),
                                      measuredViewHeight: 300)
        require(card.tearSplitPt == 340,
                "the mid-page tear is at the whitespace below the selected region: \(String(describing: card.tearSplitPt))")
        require(state.selection == before,
                "tearing the page does not change the selected characters: \(String(describing: state.selection)) vs \(before)")

        try await eventually("the selection's highlight quads appear") {
            state.canvasPages.contains { $0.placement.index >= PlacementIndex.selection(0) }
        }
        let text = try await TearLayoutEngine().textPage(0)
        let expectedRects = text.selectionRects(in: before.range)
        require(expectedRects.count >= 2, "the selection has a quad on each side of the tear")
        let quads = state.canvasPages.filter {
            $0.placement.index >= PlacementIndex.selection(0)
                && $0.placement.index < PlacementIndex.selection(10_000)
        }
        require(quads.count == expectedRects.count,
                "the tear neither drops nor duplicates a selection quad (\(quads.count) vs \(expectedRects.count))")
        let quadTops = quads.map(\.placement.topPt).sorted()
        for rect in expectedRects {
            let expectedTop = rect.minY + (rect.minY >= 340 ? 300 : 0)
            require(quadTops.contains(where: { abs($0 - expectedTop) < 0.6 }),
                    "a selection quad on the \(rect.minY >= 340 ? "bottom" : "top") side is at its page position plus the gap when needed (expected \(expectedTop), got \(quadTops))")
        }
        require(quads.allSatisfy { $0.source == CGRect(x: 0, y: 0, width: 1, height: 1) },
                "selection quads wholly on one side of the tear keep their whole tint texture")

        state.closeRegionCard(id: card.id, keepHistory: false)
        state.reloadVisiblePages()
        require(state.selection == before, "closing the tear leaves the text selection alone")
        let restored = state.canvasPages.filter {
            $0.placement.index >= PlacementIndex.selection(0)
                && $0.placement.index < PlacementIndex.selection(10_000)
        }
        require(restored.count == expectedRects.count,
                "closing the tear restores the selection quads")
    }

    // MARK: - Raster work

    @MainActor
    private static func tearRasterWorkChecks() async throws {
        // Screen-resolution path: the page is rasterized once, and the tear adds only draw-list
        // pieces over the same texture.
        let (state, engine) = makeTearState(preferFullPageRasters: true)
        try await eventually("page 0 gets its screen-resolution raster") {
            state.canvasPages.contains { $0.placement.index == PlacementIndex.pageRaster(0) }
        }
        let renderBefore = engine.renderCalls[0, default: 0]
        require(renderBefore > 0, "the screen path rendered page 0 once")
        let card = try await openCard(state, rect: CGRect(x: 100, y: 100, width: 220, height: 90),
                                      measuredViewHeight: 300)
        try await eventually("the split appears in the draw list") {
            state.canvasPages.filter { $0.placement.index == PlacementIndex.pageRaster(0) }.count == 2
        }
        require(engine.renderCalls[0, default: 0] == renderBefore,
                "opening the tear causes zero extra page rasterizations (\(engine.renderCalls[0, default: 0]) vs \(renderBefore))")
        let rasterQuads = state.canvasPages.filter { $0.placement.index == PlacementIndex.pageRaster(0) }
        require(rasterQuads.count == 2 && rasterQuads[0].image.generation == rasterQuads[1].image.generation,
                "both display segments share the one raster")
        state.closeRegionCard(id: card.id, keepHistory: false)

        // Deep zoom uses tiles. Splitting a tile shows two source rectangles over the same tile
        // bitmap; it must not schedule another tile raster for the page.
        let (tileState, tileEngine) = makeTearState(preferFullPageRasters: false)
        tileState.zoomPercent = 400
        // Put the tear point inside the (much shorter) deep-zoom viewport first, so opening the
        // card does not scroll to reach it: the count below measures the tear's raster cost, not
        // the cost of newly visible rows.
        tileState.scroll(byScreenPoints: 400)
        tileState.reloadVisiblePages()
        try await eventually("deep zoom schedules page 0 tiles") {
            tileEngine.tileCalls[0, default: 0] > 0
        }
        // Wait until the initial band has stopped issuing requests: a count taken while the
        // first batch is still in flight would attribute those tiles to the tear.
        var tileBefore = -1
        for _ in 0..<12 {
            let current = tileEngine.tileCalls[0, default: 0]
            try await Task.sleep(for: .milliseconds(150))
            if tileEngine.tileCalls[0, default: 0] == current {
                tileBefore = current
                break
            }
        }
        require(tileBefore > 0, "the tile band settles before the tear is opened")
        let scrollBeforeCard = tileState.scrollYPt
        let tileCard = try await openCard(tileState, rect: CGRect(x: 100, y: 100, width: 220, height: 90),
                                          measuredViewHeight: 300)
        require(abs(tileState.scrollYPt - scrollBeforeCard) < 0.01,
                "the deep-zoom tear is already in view, so opening the card does not scroll")
        try await Task.sleep(for: .milliseconds(300))
        for _ in 0..<8 {
            let current = tileEngine.tileCalls[0, default: 0]
            try await Task.sleep(for: .milliseconds(150))
            if tileEngine.tileCalls[0, default: 0] == current { break }
        }
        require(tileEngine.tileCalls[0, default: 0] == tileBefore,
                "opening the tear schedules zero extra tile rasters for the torn page (\(tileEngine.tileCalls[0, default: 0]) vs \(tileBefore))")
        let splitTiles = tileState.canvasPages.filter {
            $0.placement.index >= 0 && $0.source != CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        require(!splitTiles.isEmpty,
                "the deep-zoom draw list clips at least one tile at the tear")
        require(splitTiles.allSatisfy { $0.placement.heightPt > 0 },
                "no clipped tile piece is empty")
        tileState.closeRegionCard(id: tileCard.id, keepHistory: false)
    }

    // MARK: - Failures and fallbacks

    @MainActor
    private static func tearFailureChecks() async throws {
        // A selection with less than a card's height below it never cuts the page.
        let (state, _) = makeTearState()
        let nearFoot = try await openCard(state, rect: CGRect(x: 100, y: 1000, width: 220, height: 100),
                                          measuredViewHeight: 300)
        require(nearFoot.tearSplitPt == nil,
                "a selection near the page foot falls back to the page-foot gap")
        require(nearFoot.tearFallbackReason != nil,
                "the fallback names its reason")
        require(state.pageSegments(forPage: 0).count == 1,
                "a page-foot fallback leaves the page whole")
        let gapTop = state.regionGapTop(for: nearFoot.id)!
        require(abs(gapTop - 1200) < 0.001,
                "the fallback gap starts at the page foot, as before")
        let page1 = state.canvasPageFrames.first { $0.index == 1 }!
        require(abs(page1.topPt - (1200 + state.pageGapPt + state.regionGapHeightPt(nearFoot))) < 0.001,
                "the page below starts after the fallback gap")
        state.closeRegionCard(id: nearFoot.id, keepHistory: false)

        // The figure/table index is consulted in the real card path, not only by the pure rule.
        let figure = Figure(kind: "Figure", label: "1", page: 0, captionText: "A figure",
                            xPt: 40, yPt: 250, widthPt: 520, heightPt: 350)
        let (figureState, _) = makeTearState(figures: [figure])
        try await eventually("the caption index reaches the tear planner") {
            figureState.figures.count == 1
        }
        let overFigure = try await openCard(
            figureState, rect: CGRect(x: 100, y: 100, width: 220, height: 250),
            measuredViewHeight: 300
        )
        require(overFigure.tearSplitPt == 711,
                "a real card skips the figure box and tears at the whitespace below it: \(String(describing: overFigure.tearSplitPt))")
        require((overFigure.tearSplitPt ?? 0) > 600,
                "the real tear is outside the figure region (250…600)")
        figureState.closeRegionCard(id: overFigure.id, keepHistory: false)

        // Growing a response must not relocate its anchor or lose the lower paper segment.
        let (tallState, _) = makeTearState()
        let tall = try await openCard(tallState, rect: CGRect(x: 100, y: 100, width: 220, height: 90),
                                      measuredViewHeight: 300)
        tallState.updateRegionCardHeight(cardID: tall.id, viewHeight: 1400)
        tallState.reloadVisiblePages()
        require(tall.tearSplitPt == 190, "growing a conversation preserves its paper cut")
        require(tall.tearFallbackReason == nil, "growth does not create a fallback")
        require(tallState.pageSegments(forPage: 0).count == 2, "both paper segments remain")
        require(abs(tallState.regionGapHeightPt(tall) - 1400) < 0.001, "the inserted gap follows measured height")
        require(abs(tallState.regionGapTop(for: tall.id)! - 190) < 0.001, "the gap stays at the original cut")
        tallState.closeRegionCard(id: tall.id, keepHistory: false)
    }

    // MARK: - Fit Width / Fit Page

    @MainActor
    private static func tearFitChecks() async throws {
        let (state, _) = makeTearState()
        state.zoomFitPage()
        let fitPage = state.zoomPercent
        state.zoomFitWidth()
        let fitWidth = state.zoomPercent
        let (fresh, _) = makeTearState()
        fresh.zoomFitPage()
        let fitPageWithoutCard = fresh.zoomPercent
        fresh.zoomFitWidth()
        let fitWidthWithoutCard = fresh.zoomPercent
        require(fitPage == fitPageWithoutCard,
                "Fit Page computes the same zoom on a torn page (\(fitPage) vs \(fitPageWithoutCard))")
        require(fitWidth == fitWidthWithoutCard,
                "Fit Width computes the same zoom on a torn page (\(fitWidth) vs \(fitWidthWithoutCard))")
    }

    // MARK: - Annotations

    @MainActor
    private static func tearAnnotationChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-inside-tear-annotations-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("text-page.pdf")
        try fileManager.copyItem(at: root.appendingPathComponent("tests/fixtures/text-page.pdf"),
                                 to: fixture)

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        require(state.open(url: fixture), "the annotation tear fixture opens")
        try await eventually("the annotation fixture's text loads") { state.hasTextLayer(0) }
        let text = try await state.engine.textPage(0)
        let line = firstLineRect(text, pageHeight: 792)
        let card = try await openCard(state, rect: line, measuredViewHeight: 260)
        guard let split = card.tearSplitPt else {
            fatalError("FAIL: the annotation fixture received an inside tear")
        }
        require(split >= line.maxY,
                "the tear is below the selected region, never through it")

        let abovePoint = CGPoint(x: 40, y: max(10, split - 80))
        let belowPoint = CGPoint(x: 40, y: min(760, split + 80))
        require(state.addInkAnnotation(page: 0, points: [abovePoint,
                                                         CGPoint(x: abovePoint.x + 30, y: abovePoint.y)]),
                "an annotation above the tear is added")
        require(state.addInkAnnotation(page: 0, points: [belowPoint,
                                                         CGPoint(x: belowPoint.x + 30, y: belowPoint.y)]),
                "an annotation below the tear is added")
        require(state.geometryAnnotationHit(atContentPoint: CGPoint(x: 55, y: abovePoint.y))?.page == 0,
                "the annotation above the tear is hit at its page Y")
        let belowContentY = state.contentY(forPageLocalY: belowPoint.y, onPage: 0)!
        require(state.geometryAnnotationHit(atContentPoint: CGPoint(x: 55, y: belowContentY))?.page == 0,
                "the annotation below the tear is hit only after the gap is subtracted")
        require(state.geometryAnnotationHit(atContentPoint: CGPoint(x: 55, y: belowPoint.y)) == nil
                || belowPoint.y > split,
                "the below-tear annotation is not hit at the content Y of its page Y above the tear")
        state.annotationTool = .eraser
        require(state.eraserTarget(atContentPoint: CGPoint(x: 55, y: belowContentY)) != nil,
                "the eraser finds the below-tear annotation through the piecewise mapping")
        state.annotationTool = .select

        let copy = scratch.appendingPathComponent("annotated-tear.pdf")
        let saved = await state.saveAnnotatedCopy(to: copy)
        require(saved, "the annotations under the tear are written back")
        let reopened = try RustEngine()
        _ = try reopened.openDocument(at: copy)
        let annotations = try await reopened.annotations()
        let ink = annotations.filter { $0.kind.lowercased() == "ink" }
        require(ink.count >= 2, "the PDF contains both ink annotations after write-back")
        let ys = ink.flatMap { $0.inkPaths.flatMap { $0.map(\.y) } }
        require(ys.contains(where: { abs($0 - abovePoint.y) < 2 }),
                "the above-tear annotation was written at its page Y (found \(ys))")
        require(ys.contains(where: { abs($0 - belowPoint.y) < 2 }),
                "the below-tear annotation was written at its page Y, not shifted by the gap (found \(ys))")
        state.closeRegionCard(id: card.id, keepHistory: false)
    }

    // MARK: - Printing

    @MainActor
    private static func tearPrintingChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-inside-tear-printing-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("multipage.pdf")
        try fileManager.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"),
                                 to: fixture)

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        require(state.open(url: fixture), "the printing tear fixture opens")
        try await eventually("the printing fixture's text loads") { state.hasTextLayer(0) }
        guard let cleanView = state.makePrintView() else {
            fatalError("FAIL: the print view is built")
        }
        var range = NSRange()
        require(cleanView.knowsPageRange(&range) && range.length == 3,
                "printing a torn page still reports the document's three pages")
        guard let cleanBitmap = try? requireUnwrap(cleanView.renderPageBitmap(0),
                                                    "the untorn page prints") else {
            fatalError("FAIL: the untorn page prints")
        }

        let text = try await state.engine.textPage(0)
        let line = firstLineRect(text, pageHeight: 792)
        let card = try await openCard(state, rect: line, measuredViewHeight: 260)
        require(card.tearSplitPt != nil, "the printing fixture is torn")
        require(state.canvasPages.contains { $0.source != CGRect(x: 0, y: 0, width: 1, height: 1) },
                "the torn page is in the on-screen draw list")
        guard let tornView = state.makePrintView() else {
            fatalError("FAIL: the print view is built with a card open")
        }
        require(tornView.pageCount == cleanView.pageCount,
                "opening a tear does not change the printed page count")
        require(tornView.pageSizePt == cleanView.pageSizePt,
                "opening a tear does not change the printed page size")
        guard let tornBitmap = try? requireUnwrap(tornView.renderPageBitmap(0),
                                                   "the torn page prints") else {
            fatalError("FAIL: the torn page prints")
        }
        require(tornBitmap.pixelsWide == cleanBitmap.pixelsWide
                && tornBitmap.pixelsHigh == cleanBitmap.pixelsHigh,
                "the printed torn page has the original page's dimensions, not the gap")
        var differentSamples = 0
        if let a = cleanBitmap.bitmapData, let b = tornBitmap.bitmapData {
            let rowBytes = cleanBitmap.bytesPerRow
            for y in stride(from: 0, to: cleanBitmap.pixelsHigh, by: 37) {
                for x in stride(from: 0, to: cleanBitmap.pixelsWide, by: 41) {
                    let offset = y * rowBytes + x * 4
                    if a[offset] != b[offset] || a[offset + 1] != b[offset + 1]
                        || a[offset + 2] != b[offset + 2] {
                        differentSamples += 1
                    }
                }
            }
        }
        require(differentSamples == 0,
                "printing the torn page produces the original page, not a gap: \(differentSamples) differing samples")
        state.closeRegionCard(id: card.id, keepHistory: false)
    }

    // MARK: - Page edits

    @MainActor
    private static func tearPageEditChecks(root: URL) async throws {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("lyra-inside-tear-edits-\(UUID())")
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let fixture = scratch.appendingPathComponent("multipage.pdf")
        try fileManager.copyItem(at: root.appendingPathComponent("tests/fixtures/multipage.pdf"),
                                 to: fixture)

        let state = AppState(engine: try RustEngine())
        state.setViewportSize(CGSize(width: 900, height: 700))
        require(state.open(url: fixture), "the page-edit tear fixture opens")
        try await eventually("the page-edit fixture's text loads") { state.hasTextLayer(0) }
        let text = try await state.engine.textPage(0)
        let line = firstLineRect(text, pageHeight: 792)
        let card = try await openCard(state, rect: line, measuredViewHeight: 260)
        require(card.tearSplitPt != nil, "the page-edit fixture has an inside tear")
        card.question = "Does a rotation keep this card?"

        let applied = await state.applyPageEditOperation(
            .rotate(pages: [0], quarterTurns: 1), label: "Rotate"
        )
        require(applied, "the page rotation applies")
        require(state.regionCards.isEmpty,
                "a page edit closes the open card")
        require(state.pageTear(forPage: 0) == nil,
                "a page edit removes the tear instead of pointing it at changed geometry")
        require(state.pageSegments(forPage: 0).count == 1,
                "after the page edit the page is whole again")
        let saved = state.currentRegionHistory.first { $0.id == card.id }
        require(saved?.draftQuestion == "Does a rotation keep this card?",
                "a page edit preserves the unsent draft")
        require(saved?.locationInvalidated == true,
                "a page edit invalidates the original region coordinates")
        require(saved.map { state.reopenRegionCard(from: $0) == nil } == true,
                "an invalidated selection cannot reopen at stale coordinates")
    }
}
