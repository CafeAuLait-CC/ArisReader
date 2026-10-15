import ArisReaderKit
import Foundation

@MainActor private final class ScreenPageEngine: PreviewEngine {
    private var waiting: [Int: (CGFloat, CheckedContinuation<PageImage, Error>)] = [:]
    private var automatic = false
    var pendingPages: Set<Int> { Set(waiting.keys) }
    var tileRequests = 0
    var undersized = false
    var failingPages: Set<Int> = []
    let pageHeight: CGFloat
    init(pageHeight: CGFloat = 800) { self.pageHeight = pageHeight }

    override func openDocument(at url: URL) throws -> LoadedDocument {
        LoadedDocument(title: "Screen page fixture", pageCount: 8, url: url,
                       firstPageSize: CGSize(width: 600, height: pageHeight))
    }
    override func renderPage(_ page: Int, scale: CGFloat) async throws -> PageImage {
        // Sidebar supersampling is separate from the screen-resolution scheduler.
        if scale < 2 {
            return PageImage(pixelWidth: 1, pixelHeight: 1, pointSize: CGSize(width: 600, height: pageHeight),
                             bgra: Data([255, 255, 255, 255]), generation: UInt64(100 + page))
        }
        if failingPages.contains(page) { throw NSError(domain: "ScreenPageChecks", code: 2) }
        if automatic { return image(page, scale: scale) }
        return try await withCheckedThrowingContinuation { waiting[page] = (scale, $0) }
    }
    private func image(_ page: Int, scale: CGFloat) -> PageImage {
        let width = undersized ? 1 : Int(ceil(600 * scale))
        let height = undersized ? 1 : Int(ceil(pageHeight * scale))
        return PageImage(pixelWidth: width, pixelHeight: height, pointSize: CGSize(width: 600, height: pageHeight),
                         bgra: Data(repeating: 255, count: width * height * 4), generation: UInt64(200 + page))
    }
    func finish(_ page: Int) {
        guard let (scale, continuation) = waiting.removeValue(forKey: page) else { return }
        continuation.resume(returning: image(page, scale: scale))
    }
    func finishAll() {
        automatic = true
        for page in pendingPages { finish(page) }
    }
    override func rasterizeTile(page: Int, lod: UInt8, tileX: Int, tileY: Int, tileSize: Int) async throws -> TileImage {
        tileRequests += 1
        throw NSError(domain: "ScreenPageChecks", code: 1)
    }
    override func contentWidthPt(gapPt: CGFloat) -> CGFloat { 600 }
    override func contentHeightPt(gapPt: CGFloat) -> CGFloat { pageHeight * 8 }
    override func pageTopPt(_ index: Int, gapPt: CGFloat) -> CGFloat { CGFloat(index) * pageHeight }
    override func pageIndex(atScrollYPt y: CGFloat, gapPt: CGFloat) -> Int { min(7, max(0, Int(y / pageHeight))) }
    override func visiblePages(scrollYPt y: CGFloat, viewportHeightPt h: CGFloat,
                               gapPt: CGFloat, marginPt m: CGFloat) -> [PagePlacement] {
        (0..<8).compactMap { index in
            let top = CGFloat(index) * pageHeight
            guard top + pageHeight >= y - m, top <= y + h + m else { return nil }
            return PagePlacement(index: index, topPt: top, leftPt: 0, widthPt: 600, heightPt: 800)
        }
    }
}

extension ReaderChecks {
    @MainActor static func screenPageChecks(url: URL) async throws {
        let engine = ScreenPageEngine()
        defer { engine.finishAll() }
        let state = AppState(engine: engine, tileCacheBudgetBytes: 48 * 1024 * 1024,
                             preferFullPageRasters: true)
        state.zoomPercent = 140
        state.setViewportSize(CGSize(width: 900, height: 700))
        state.open(url: url)
        state.gotoPage(0)
        try await eventually("cold page is the first screen-resolution request", { engine.pendingPages == [0] })
        require(engine.tileRequests == 0, "a cold normal-zoom page does not queue a diagonal tile sweep")
        engine.finish(0)
        try await eventually("cold page appears as one native-resolution image", {
            state.canvasPages.contains { $0.image.generation == 200 && $0.image.pixelWidth == 1680 }
        })
        try await eventually("screen-resolution neighbors fill the pixel budget", {
            for page in engine.pendingPages { engine.finish(page) }
            return state.pageRasterCacheCount == 3 && engine.pendingPages.isEmpty
        })
        require(state.tileCacheUsedBytes + state.pageRasterCacheUsedBytes <= state.tileCacheBudgetBytes,
                "page snapshots share the byte budget instead of adding an unbounded second cache")
        state.scroll(byScreenPoints: 2240) // two pages in one event: a fast wheel destination.
        require(state.isScrolling && state.isScreenPageCached(2)
                && state.canvasPages.contains { $0.image.generation == 202 },
                "a fast wheel destination is immediately sharp from the prepared neighborhood")
        try await eventually("new neighbor starts before scrolling goes idle", {
            state.isScrolling && engine.pendingPages == [3]
        })
        state.gotoPage(7)
        engine.finish(3) // at most one old page request was already running.
        try await eventually("a cold jump reprioritizes the latest destination", { engine.pendingPages == [7] })
        require(!state.canvasPages.contains { $0.image.generation == 203 },
                "late page rasters cannot flash over the new destination")
        engine.finish(7)
        try await eventually("distant destination also promotes as one sharp image", { state.isScreenPageCached(7) })
        require(engine.tileRequests == 0, "normal zoom does not duplicate sharp page rasters with tile work")

        let lowEngine = ScreenPageEngine()
        lowEngine.finishAll()
        let low = AppState(engine: lowEngine, tileCacheBudgetBytes: 48 * 1024 * 1024,
                           preferFullPageRasters: true)
        low.zoomPercent = 100
        low.setViewportSize(CGSize(width: 900, height: 700))
        low.open(url: url)
        low.gotoPage(3)
        try await eventually("lower zoom retains a wider sharp neighborhood", { low.pageRasterCacheCount >= 5 })
        require(low.pageRasterCacheUsedBytes <= low.tileCacheBudgetBytes,
                "lower zoom expands by byte cost rather than a fixed unbounded page count")
        low.applyCacheBudgetSetting(environment: ["ARIS_READER_CACHE_BUDGET_MB": "16"])
        require(low.pageRasterCacheUsedBytes + low.tileCacheUsedBytes <= 16 * 1024 * 1024,
                "reducing the live budget immediately shrinks the page neighborhood")
        low.applyCacheBudgetSetting(environment: ["ARIS_READER_CACHE_BUDGET_MB": "48"])
        try await eventually("raising the live budget refills more nearby pages", { low.pageRasterCacheCount >= 5 })
        low.zoomPercent = 400
        low.reloadVisiblePages()
        try await eventually("deep zoom keeps using the bounded tile path", { lowEngine.tileRequests > 0 })
        require(!low.usesScreenPageRasters, "oversized full-page allocations are avoided at deep zoom")

        let clampedEngine = ScreenPageEngine()
        clampedEngine.undersized = true
        clampedEngine.finishAll()
        let clamped = AppState(engine: clampedEngine, preferFullPageRasters: true)
        clamped.zoomPercent = 140
        clamped.setViewportSize(CGSize(width: 900, height: 700))
        clamped.open(url: url)
        clamped.gotoPage(0)
        try await eventually("an undersized backend result falls back to tiles", { clampedEngine.tileRequests > 0 })
        require(!clamped.isScreenPageCached(0), "undersized images cannot count as sharp cache hits")

        let failedEngine = ScreenPageEngine()
        failedEngine.failingPages = [0]
        failedEngine.finishAll()
        let failed = AppState(engine: failedEngine, preferFullPageRasters: true)
        failed.zoomPercent = 140
        failed.setViewportSize(CGSize(width: 900, height: 700))
        failed.open(url: url)
        failed.gotoPage(0)
        try await eventually("a failed screen-page request falls back to tile work", { failedEngine.tileRequests > 0 })

        let tinyEngine = ScreenPageEngine(pageHeight: 40)
        tinyEngine.finishAll()
        let tiny = AppState(engine: tinyEngine, preferFullPageRasters: true)
        tiny.zoomPercent = 140
        tiny.setViewportSize(CGSize(width: 900, height: 700))
        tiny.open(url: url)
        tiny.gotoPage(0)
        try await eventually("many short visible pages retain the tile fallback", { tinyEngine.tileRequests > 0 })
        require(!tiny.usesScreenPageRasters,
                "the page-count ceiling cannot leave a visible page permanently without raster work")
    }
}
