import ArisReaderKit
import Foundation

/// An engine whose 10 pages are laid out like `PreviewEngine`'s (`pageTopPt = 1200 × index`),
/// so a viewport update has a band to build, and which counts the tiles it rasterized. The
/// count is the measurement `prefetchBandChecks` needs: "zoom back reuses the cache" is a
/// statement about rasters that did *not* happen.
@MainActor private final class BandTileEngine: PreviewEngine {
    private(set) var tileRasters = 0
    private(set) var rasterizedKeys: [TileKey] = []

    override func rasterizeTile(page: Int, lod: UInt8, tileX: Int, tileY: Int, tileSize: Int) async throws -> TileImage {
        tileRasters += 1
        rasterizedKeys.append(TileKey(page: page, lod: lod, x: tileX, y: tileY))
        return TileImage(page: page, lod: lod, tileX: tileX, tileY: tileY, sizePx: tileSize,
                         bgra: Data(repeating: 200, count: tileSize * tileSize * 4),
                         generation: UInt64(9000 + page * 100 + tileY * 10 + tileX))
    }

    override func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        PageImage(pixelWidth: 1, pixelHeight: 1, pointSize: CGSize(width: 600, height: 1200),
                  bgra: Data([255, 255, 255, 255]), generation: UInt64(800 + page))
    }

    override func visiblePages(scrollYPt: CGFloat, viewportHeightPt: CGFloat, gapPt: CGFloat, marginPt: CGFloat) -> [PagePlacement] {
        (0..<10).compactMap { page in
            let top = CGFloat(page) * 1200
            guard top + 1200 >= scrollYPt - marginPt, top <= scrollYPt + viewportHeightPt + marginPt else { return nil }
            return PagePlacement(index: page, topPt: top, leftPt: 0, widthPt: 600, heightPt: 1200)
        }
    }

    override func contentHeightPt(gapPt: CGFloat) -> CGFloat { 12_000 }

    override func pageIndex(atScrollYPt scrollYPt: CGFloat, gapPt: CGFloat) -> Int {
        min(9, max(0, Int(scrollYPt / 1200)))
    }
}

extension ReaderChecks {
    /// The adaptive prefetch band's invariants.
    ///
    /// ADR 0007 fixed the band at 3.5 viewports of every column; the scheduler change bounds it
    /// in bytes instead. Three things must stay true whatever the budget decides, and each is
    /// asserted here rather than argued in a comment:
    ///
    /// 1. **The band contains the viewport.** The ring can shrink to the floor; it can never
    ///    shrink past the tiles the reader is looking at. (The floor is not decoration: an
    ///    earlier split subtracted the ring from the viewport's own height, and the "cheaper"
    ///    configuration it produced was cheaper because it stopped wanting visible tiles.)
    /// 2. **The band stops at columns the viewport can reveal.** At 400% zoom a 600pt page is
    ///    10 columns wide and 3 of them are on screen; the canvas left-aligns a page wider than
    ///    the viewport and there is no horizontal scrolling, so the other 7 could only be
    ///    revealed by a widening window — one column of ring covers that.
    /// 3. **A zoom in → out → in sequence rasterizes nothing on the way back.** This is the
    ///    interaction the cache study pinned at a 48 MB budget: two adjacent LODs of a page have
    ///    to fit together, or zooming back re-rasterizes.
    @MainActor static func prefetchBandChecks(url: URL) async throws {
        let viewport = CGSize(width: 700, height: 500)
        let engine = BandTileEngine()
        let state = AppState(engine: engine)
        state.setViewportSize(viewport)
        require(state.open(url: url), "band fixture opens")
        state.gotoPage(0)

        /// The transform `PDFCanvasView.renderFrame` applies: content is centred when the
        /// viewport is wider, so the visible window is its left edge when the page is wider.
        func visibleRect() -> CGRect {
            let zoom = max(CGFloat(state.zoomPercent) / 100, 0.01)
            let centreOffset = max(0, (viewport.width - state.contentWidthPt * zoom) / 2)
            return CGRect(x: -centreOffset / zoom, y: state.scrollYPt,
                          width: viewport.width / zoom, height: viewport.height / zoom)
        }

        /// Every tile of the current LOD that the viewport can show must be wanted.
        func uncoveredTile() -> TileKey? {
            guard let lod = state.pinnedTiles.first?.lod else { return TileKey(page: -1, lod: 0, x: 0, y: 0) }
            let tilePt = 512 / CGFloat(1 << Int(lod))
            let rect = visibleRect()
            let pages = engine.visiblePages(scrollYPt: state.scrollYPt, viewportHeightPt: rect.height,
                                            gapPt: state.pageGapPt, marginPt: 0)
            for placement in pages {
                let columns = max(1, Int(ceil(placement.widthPt / tilePt)))
                let rows = max(1, Int(ceil(placement.heightPt / tilePt)))
                for ty in 0..<rows {
                    for tx in 0..<columns {
                        let tile = CGRect(x: placement.leftPt + CGFloat(tx) * tilePt,
                                          y: placement.topPt + CGFloat(ty) * tilePt,
                                          width: tilePt, height: tilePt)
                        guard tile.intersects(rect) else { continue }
                        let key = TileKey(page: placement.index, lod: lod, x: tx, y: ty)
                        if !state.pinnedTiles.contains(key) { return key }
                    }
                }
            }
            return nil
        }

        /// Columns the band wants, per page, at the current zoom.
        func wantedColumns() -> Set<Int> { Set(state.pinnedTiles.map(\.x)) }

        /// Waits until an engine's tile raster count has been still for a while: the scheduler's
        /// queues are private, and "the band has settled" is exactly "no new raster" from here.
        func quiesce(_ engine: BandTileEngine) async {
            var last = -1
            var quiet = 0
            for _ in 0..<400 {
                try? await Task.sleep(for: .milliseconds(25))
                if engine.tileRasters == last {
                    quiet += 1
                    if quiet >= 4 { return }
                } else {
                    quiet = 0
                    last = engine.tileRasters
                }
            }
            fatalError("TIMEOUT: the band never settled")
        }
        func settle() async throws { await quiesce(engine) }

        for zoom in [100, 200, 400] {
            for fraction in [0.0, 0.35, 0.7] {
                state.zoomPercent = zoom
                state.gotoPage(0)
                state.scroll(toFraction: fraction)
                state.reloadVisiblePages()
                try await settle()
                if let missing = uncoveredTile() {
                    fatalError("FAIL: at \(zoom)% the band does not want the visible tile \(missing)")
                }
            }
        }
        print("PASS: every zoom and scroll position keeps the tiles the viewport shows in the wanted band")

        // The column rule: off-screen columns beyond one column of ring are not wanted. At 400%
        // the 600pt page is 10 columns wide (64pt tiles) and ~3 are on screen.
        state.zoomPercent = 400
        state.gotoPage(0)
        state.reloadVisiblePages()
        try await settle()
        let tilePt = 512.0 / 8.0
        let visibleLastColumn = Int(floor((visibleRect().maxX - 0) / tilePt))
        let wanted = wantedColumns()
        require(wanted.max() ?? 0 <= visibleLastColumn + 1,
                "the band stops one column past the viewport (\(wanted.max() ?? -1) <= \(visibleLastColumn + 1))")
        require(wanted.count <= visibleLastColumn + 2,
                "the unreachable columns of a page wider than the viewport are not wanted")

        // 3. Zoom in → out → in: the two legs back must rasterize nothing. A fresh state and a
        // fresh engine, because the checks above already warmed both LODs — reusing *those*
        // tiles would prove nothing about a reader who zooms for the first time.
        let zoomEngine = BandTileEngine()
        let zoomState = AppState(engine: zoomEngine)
        zoomState.setViewportSize(viewport)
        require(zoomState.open(url: url), "band fixture opens for the zoom sequence")
        zoomState.gotoPage(0)
        await quiesce(zoomEngine)
        let atDefaultZoom = zoomEngine.tileRasters
        require(atDefaultZoom > 0, "the default zoom fills its band (\(atDefaultZoom) tiles)")

        zoomState.zoomPercent = 400
        zoomState.reloadVisiblePages()
        await quiesce(zoomEngine)
        let afterZoomIn = zoomEngine.tileRasters
        require(afterZoomIn > atDefaultZoom, "zooming to a new LOD rasterizes that LOD")

        zoomState.zoomPercent = 100
        zoomState.reloadVisiblePages()
        await quiesce(zoomEngine)
        require(zoomEngine.tileRasters == afterZoomIn,
                "zooming back out reuses the cached LOD (rasterized \(zoomEngine.tileRasters - afterZoomIn))")

        zoomState.zoomPercent = 400
        zoomState.reloadVisiblePages()
        await quiesce(zoomEngine)
        require(zoomEngine.tileRasters == afterZoomIn,
                "zooming in again reuses the cached LOD (rasterized \(zoomEngine.tileRasters - afterZoomIn))")
        print("PASS: zoom in → out → in rasterizes \(afterZoomIn - atDefaultZoom) tile(s) once and nothing on the way back")
    }
}
